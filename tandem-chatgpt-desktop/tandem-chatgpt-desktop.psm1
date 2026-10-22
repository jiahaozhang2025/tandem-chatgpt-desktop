#Requires -Version 5.1
<#
tandem-chatgpt-desktop: run the ChatGPT desktop app for Windows (Microsoft Store package
OpenAI.Codex) as several isolated instances, one per account, side by side.

How it works
  The app keeps its login and Codex state in CODEX_HOME and its window and browser
  data in CODEX_ELECTRON_USER_DATA_PATH, and it allows one running instance per data
  folder. A Store app only runs with its package identity, and
  Invoke-CommandInDesktopPackage passes arguments but not environment variables. So
  each launch runs a small cmd.exe wrapper inside the package (-PreventBreakaway keeps
  everything it starts there) that sets both variables and starts ChatGPT.exe.

Safety check
  If the variables ever stop reaching the app, it falls back to ~\.codex and would
  share the main account's login. After every launch we wait for the app to write to
  the profile's own CODEX_HOME, and close it if it does not.
#>

Set-StrictMode -Version 3.0
Add-Type -AssemblyName System.Drawing

$script:PackageName = 'OpenAI.Codex'
$script:AppId = 'App'
$script:NamePattern = '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
$script:EnvVarNames = @('CODEX_HOME', 'CODEX_ELECTRON_USER_DATA_PATH')
$script:Palette = [ordered]@{
    Orange = '#E8590C'
    Blue   = '#1C7ED6'
    Green  = '#2F9E44'
    Purple = '#7048E8'
    Red    = '#E03131'
    Teal   = '#0C8599'
    Pink   = '#D6336C'
    Gray   = '#495057'
}

#region Private helpers

function Get-DefaultProfileRoot {
    Join-Path -Path $env:USERPROFILE -ChildPath 'tandem-chatgpt-desktop'
}

function Resolve-ProfileRoot {
    param([Parameter(Mandatory)][string]$Root)
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($full.Length -le 2) {
        throw "Profile root '$Root' is a drive root. Choose a folder, for example C:\tandem-chatgpt-desktop."
    }
    if ($full -match '[^\x20-\x7E]') {
        throw "Profile root '$full' contains non-ASCII characters, which the cmd.exe launch wrapper cannot pass reliably. Use -Root with an ASCII-only folder, for example C:\tandem-chatgpt-desktop."
    }
    if ($full.Contains('%')) {
        throw "Profile root '$full' contains '%', which cmd.exe would expand. Choose another folder with -Root."
    }
    $full
}

function Assert-ProfileName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if ($Name -notmatch $script:NamePattern) {
        throw "Invalid profile name '$Name'. Use 1-64 letters, digits, '-' or '_', starting with a letter or digit."
    }
}

function Get-ProfileLayout {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Root
    )
    Assert-ProfileName -Name $Name
    $rootPath = Resolve-ProfileRoot -Root $Root
    $dir = Join-Path -Path $rootPath -ChildPath $Name
    $codexHome = Join-Path -Path $dir -ChildPath 'codex-home'
    $userData = Join-Path -Path $dir -ChildPath 'electron'
    [pscustomobject]@{
        Name        = $Name
        Root        = $rootPath
        Dir         = $dir
        CodexHome   = $codexHome
        UserData    = $userData
        UserDataArg = '--user-data-dir="' + $userData + '"'
        Config      = Join-Path -Path $codexHome -ChildPath 'config.toml'
        Meta        = Join-Path -Path $dir -ChildPath 'profile.json'
        LaunchCmd   = Join-Path -Path $dir -ChildPath 'launch.cmd'
        Log         = Join-Path -Path $dir -ChildPath 'launcher.log'
    }
}

function Get-ChatGPTPackage {
    $package = Get-AppxPackage -Name $script:PackageName |
        Sort-Object -Property { [version]$_.Version } -Descending |
        Select-Object -First 1
    if ($null -eq $package) {
        throw "The ChatGPT desktop app is not installed. Install ChatGPT from the Microsoft Store (package $script:PackageName)."
    }
    $appDir = Join-Path -Path $package.InstallLocation -ChildPath 'app'
    [pscustomobject]@{
        Version    = [string]$package.Version
        FamilyName = $package.PackageFamilyName
        Exe        = Join-Path -Path $appDir -ChildPath 'ChatGPT.exe'
        BaseIcon   = Join-Path -Path $appDir -ChildPath 'resources\icon-chatgpt.ico'
        Assets     = Join-Path -Path $package.InstallLocation -ChildPath 'assets'
        Bundle     = Join-Path -Path $appDir -ChildPath 'resources\app.asar'
    }
}

function Initialize-ProfileFolder {
    param([Parameter(Mandatory)]$Layout)
    $null = New-Item -ItemType Directory -Force -Path $Layout.CodexHome, $Layout.UserData
    if (-not (Test-Path -LiteralPath $Layout.Config)) {
        # Keep this profile's login in its own auth.json rather than the OS keyring.
        Set-Content -LiteralPath $Layout.Config -Encoding Ascii -Value 'cli_auth_credentials_store = "file"'
    }
}

function Get-LaunchScriptLine {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$Exe
    )
    @(
        '@echo off'
        'set "CODEX_HOME=' + $Layout.CodexHome + '"'
        'set "CODEX_ELECTRON_USER_DATA_PATH=' + $Layout.UserData + '"'
        'start "" "' + $Exe + '" ' + $Layout.UserDataArg
    )
}

function Invoke-InPackage {
    param(
        [Parameter(Mandatory)][string]$FamilyName,
        [Parameter(Mandatory)][string]$ScriptPath
    )
    $cmd = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe'
    $null = Invoke-CommandInDesktopPackage -PackageFamilyName $FamilyName -AppId $script:AppId `
        -Command $cmd -Args ('/d /c "' + $ScriptPath + '"') -PreventBreakaway
}

# Main (non-helper) ChatGPT.exe processes of every instance.
function Get-ChatGPTMainProcess {
    Get-CimInstance -ClassName Win32_Process -Filter "Name='ChatGPT.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' }
}

function Get-ProfileProcess {
    param(
        [Parameter(Mandatory)]$Layout,
        [object[]]$Process
    )
    if (-not $PSBoundParameters.ContainsKey('Process')) { $Process = @(Get-ChatGPTMainProcess) }
    $Process | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($Layout.UserDataArg, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }
}

# Process ids of the given processes and all their descendants, leaves first.
function Get-ProcessTreeId {
    param([Parameter(Mandatory)][int[]]$RootId)
    $all = @(Get-CimInstance -ClassName Win32_Process | Select-Object -Property ProcessId, ParentProcessId, CreationDate)
    $byId = @{}
    foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
    $order = New-Object -TypeName 'System.Collections.Generic.List[int]'
    $queue = New-Object -TypeName 'System.Collections.Generic.Queue[int]'
    foreach ($id in $RootId) { $queue.Enqueue($id) }
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        if ($order.Contains($id)) { continue }
        $order.Add($id)
        $parent = $byId[$id]
        foreach ($p in $all) {
            # A child cannot predate its parent; this skips processes whose parent id was reused.
            if ($p.ParentProcessId -eq $id -and $p.ProcessId -ne $id -and
                ($null -eq $parent -or $p.CreationDate -ge $parent.CreationDate)) {
                $queue.Enqueue([int]$p.ProcessId)
            }
        }
    }
    $order.Reverse()
    $order
}

# Ends the profile's instance and everything it started, and returns how many instances
# were running. There is no gentler way: closing the window only hides ChatGPT to the
# tray, it ignores taskkill without /F, and it has no command-line quit option.
function Close-ProfileProcess {
    param([Parameter(Mandatory)]$Layout)
    $main = @(Get-ProfileProcess -Layout $Layout)
    if ($main.Count -eq 0) { return 0 }
    $ids = Get-ProcessTreeId -RootId @($main | ForEach-Object { [int]$_.ProcessId })
    foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    $main.Count
}

function Test-FreshWrite {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][datetime]$Since
    )
    $hit = Get-ChildItem -LiteralPath $Path -Recurse -Depth 1 -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since } |
        Select-Object -First 1
    $null -ne $hit
}

function Write-ProfileLog {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$Message
    )
    try {
        if ((Test-Path -LiteralPath $Layout.Log) -and (Get-Item -LiteralPath $Layout.Log).Length -gt 256KB) {
            Move-Item -LiteralPath $Layout.Log -Destination ($Layout.Log + '.old') -Force
        }
        Add-Content -LiteralPath $Layout.Log -Encoding Ascii -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    } catch {
        Write-Verbose "Could not write to $($Layout.Log): $_"
    }
}

function Read-ProfileMeta {
    param([Parameter(Mandatory)]$Layout)
    if (-not (Test-Path -LiteralPath $Layout.Meta)) { return $null }
    try {
        Get-Content -LiteralPath $Layout.Meta -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Ignoring unreadable $($Layout.Meta): $_"
        $null
    }
}

function Get-MetaValue {
    param($Meta, [Parameter(Mandatory)][string]$Key, $Default)
    if ($null -ne $Meta -and $Meta.PSObject.Properties[$Key] -and $null -ne $Meta.$Key) { return $Meta.$Key }
    $Default
}

function Save-ProfileMeta {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Meta
    )
    $Meta | ConvertTo-Json | Set-Content -LiteralPath $Layout.Meta -Encoding UTF8
}

function Get-NextColor {
    param([Parameter(Mandatory)][string]$Root)
    $count = 0
    if (Test-Path -LiteralPath $Root) {
        $count = @(Get-ChildItem -LiteralPath $Root -Directory | Where-Object {
                Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'codex-home')
            }).Count
    }
    @($script:Palette.Keys)[$count % $script:Palette.Count]
}

function Get-ShortcutFolder {
    param([switch]$Desktop, [switch]$StartMenu)
    if ($Desktop) { [Environment]::GetFolderPath('Desktop') }
    if ($StartMenu) { [Environment]::GetFolderPath('Programs') }
}

function Save-ProfileShortcut {
    param(
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Icon
    )
    $cli = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'chatgpt-profile.ps1'
    if (-not (Test-Path -LiteralPath $cli)) { throw "Launcher script not found: $cli" }
    $fileLabel = ($Label -replace '[\\/:*?"<>|]', '').Trim()
    if (-not $fileLabel) { $fileLabel = $Layout.Name }
    $path = Join-Path -Path $Folder -ChildPath "ChatGPT ($fileLabel).lnk"
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($path)
        $link.TargetPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $link.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" launch {1} -Root "{2}" -Gui' -f $cli, $Layout.Name, $Layout.Root
        $link.WorkingDirectory = $Layout.Dir
        $link.IconLocation = $Icon + ',0'
        $link.WindowStyle = 7
        $link.Description = "ChatGPT, separate profile '$($Layout.Name)'"
        $link.Save()
    } finally {
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    $path
}

function Write-ShortcutIcon {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Icon
    )
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($Path)
        $link.IconLocation = $Icon + ',0'
        $link.Save()
    } finally {
        $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

#endregion

#region Icons

# PNG bytes of the largest PNG-encoded frame in an .ico file, or $null if it has none.
function Get-IcoPngFrame {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 6 -or [BitConverter]::ToUInt16($bytes, 2) -ne 1) { throw "Not an .ico file: $Path" }
    $count = [BitConverter]::ToUInt16($bytes, 4)
    $best = $null
    $bestSize = -1
    for ($i = 0; $i -lt $count; $i++) {
        $entry = 6 + 16 * $i
        $size = [int]$bytes[$entry]
        if ($size -eq 0) { $size = 256 }
        $length = [int][BitConverter]::ToUInt32($bytes, $entry + 8)
        $offset = [int][BitConverter]::ToUInt32($bytes, $entry + 12)
        $isPng = $bytes[$offset] -eq 0x89 -and $bytes[$offset + 1] -eq 0x50 -and $bytes[$offset + 2] -eq 0x4E -and $bytes[$offset + 3] -eq 0x47
        if ($isPng -and $size -gt $bestSize) {
            $best = New-Object -TypeName byte[] -ArgumentList $length
            [Array]::Copy($bytes, $offset, $best, 0, $length)
            $bestSize = $size
        }
    }
    , $best
}

function Get-BaseBitmap {
    param([Parameter(Mandatory)][string]$Path)
    # System.Drawing cannot decode large PNG frames through Icon, so read the PNG directly.
    $png = Get-IcoPngFrame -Path $Path
    if ($null -ne $png) {
        $stream = New-Object -TypeName IO.MemoryStream -ArgumentList (, $png)
        $image = [System.Drawing.Image]::FromStream($stream)
        try { return New-Object -TypeName System.Drawing.Bitmap -ArgumentList $image }
        finally { $image.Dispose(); $stream.Dispose() }
    }
    $icon = New-Object -TypeName System.Drawing.Icon -ArgumentList $Path, 256, 256
    try { $icon.ToBitmap() } finally { $icon.Dispose() }
}

# The flat logo the app itself shows in Start on dark backgrounds, at the requested
# size when the Store package ships one (small sizes are drawn by hand for clarity).
function Get-LogoBitmap {
    param(
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)][int]$Size
    )
    $candidates = @(Get-ChildItem -LiteralPath $App.Assets -Filter 'Square44x44Logo.targetsize-*' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.Name -match '^Square44x44Logo\.targetsize-(\d+)_altform-unplated\.png$') {
                    [pscustomobject]@{ Path = $_.FullName; Size = [int]$Matches[1] }
                }
            })
    $pick = $candidates | Where-Object { $_.Size -eq $Size } | Select-Object -First 1
    if ($null -eq $pick) { $pick = $candidates | Sort-Object -Property Size -Descending | Select-Object -First 1 }
    if ($null -eq $pick) {
        # Older app versions: use the window icon; tinting still turns it into a flat silhouette.
        return Get-BaseBitmap -Path $App.BaseIcon
    }
    # Read the bytes first so the file is not kept locked.
    $stream = New-Object -TypeName IO.MemoryStream -ArgumentList (, [IO.File]::ReadAllBytes($pick.Path))
    $image = [System.Drawing.Image]::FromStream($stream)
    try { New-Object -TypeName System.Drawing.Bitmap -ArgumentList $image }
    finally { $image.Dispose(); $stream.Dispose() }
}

# Draws the logo at the given size with every pixel in the profile color, keeping its transparency.
function ConvertTo-TintedPng {
    param(
        [Parameter(Mandatory)][System.Drawing.Image]$Base,
        [Parameter(Mandatory)][int]$Size,
        [Parameter(Mandatory)][string]$ColorHex
    )
    $color = [System.Drawing.ColorTranslator]::FromHtml($ColorHex)
    $matrix = New-Object -TypeName System.Drawing.Imaging.ColorMatrix
    $matrix.Matrix00 = 0
    $matrix.Matrix11 = 0
    $matrix.Matrix22 = 0
    $matrix.Matrix40 = $color.R / 255
    $matrix.Matrix41 = $color.G / 255
    $matrix.Matrix42 = $color.B / 255
    $attributes = New-Object -TypeName System.Drawing.Imaging.ImageAttributes
    $attributes.SetColorMatrix($matrix)
    # Without this, scaling blends the transparent area outside the image into the edges.
    $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
    $bitmap = New-Object -TypeName System.Drawing.Bitmap -ArgumentList $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $target = New-Object -TypeName System.Drawing.Rectangle -ArgumentList 0, 0, $Size, $Size
        $graphics.DrawImage($Base, $target, 0, 0, $Base.Width, $Base.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
        $stream = New-Object -TypeName IO.MemoryStream
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            , $stream.ToArray()
        } finally { $stream.Dispose() }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
        $attributes.Dispose()
    }
}

# The bytes of an .ico whose frames are PNG images (supported since Windows Vista).
function ConvertTo-IcoByte {
    param([Parameter(Mandatory)][object[]]$Frame)
    $stream = New-Object -TypeName IO.MemoryStream
    $writer = New-Object -TypeName IO.BinaryWriter -ArgumentList $stream
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$Frame.Count)
        $offset = 6 + 16 * $Frame.Count
        foreach ($f in $Frame) {
            $dim = [byte]0
            if ($f.Size -lt 256) { $dim = [byte]$f.Size }
            $writer.Write($dim)
            $writer.Write($dim)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$f.Bytes.Length)
            $writer.Write([uint32]$offset)
            $offset += $f.Bytes.Length
        }
        foreach ($f in $Frame) { $writer.Write([byte[]]$f.Bytes) }
        $writer.Flush()
        , $stream.ToArray()
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

# Writes the profile's icon and returns its path. The file name comes from the icon's
# contents, so a changed icon gets a new name: Windows caches shortcut icons by path.
function Save-ProfileIcon {
    param(
        [Parameter(Mandatory)]$App,
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$ColorHex
    )
    $frames = foreach ($size in 256, 48, 32, 24, 16) {
        $base = Get-LogoBitmap -App $App -Size $size
        try { [pscustomobject]@{ Size = $size; Bytes = (ConvertTo-TintedPng -Base $base -Size $size -ColorHex $ColorHex) } }
        finally { $base.Dispose() }
    }
    $bytes = ConvertTo-IcoByte -Frame @($frames)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join @($sha.ComputeHash($bytes)[0..3] | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    $path = Join-Path -Path $Layout.Dir -ChildPath "icon-$hash.ico"
    if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllBytes($path, $bytes) }
    $path
}

#endregion

#region Doctor helpers

# Streams a (large) file and reports which of the ASCII strings it contains.
function Test-FileContainsText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Text,
        [ValidateRange(16, 1GB)][int]$ChunkSize = 8MB
    )
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $pending = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($t in $Text) { $pending.Add($t) }
    $overlap = [int](($Text | Measure-Object -Property Length -Maximum).Maximum) - 1
    $buffer = New-Object -TypeName byte[] -ArgumentList $ChunkSize
    $stream = [IO.File]::OpenRead($Path)
    try {
        $tail = ''
        while ($pending.Count -gt 0) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $window = $tail + $latin1.GetString($buffer, 0, $read)
            foreach ($t in @($pending)) {
                if ($window.IndexOf($t, [StringComparison]::Ordinal) -ge 0) { $null = $pending.Remove($t) }
            }
            $tail = $window
            if ($window.Length -gt $overlap) { $tail = $window.Substring($window.Length - $overlap) }
        }
    } finally {
        $stream.Dispose()
    }
    $found = [ordered]@{}
    foreach ($t in $Text) { $found[$t] = -not $pending.Contains($t) }
    $found
}

function Get-CheckResult {
    param([string]$Check, [ValidateSet('OK', 'FAIL', 'SKIP')][string]$Status, [string]$Detail)
    [pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail }
}

#endregion

#region Public commands

function New-ChatGPTProfile {
    <#
    .SYNOPSIS
    Creates (or updates) a separate ChatGPT profile and its shortcuts.
    .DESCRIPTION
    Creates <Root>\<Name> with its own login folder (CODEX_HOME) and window data
    folder, an icon showing the ChatGPT logo in the profile's color, and a
    "ChatGPT (<Label>)" shortcut on the desktop and in the Start menu. Running it again
    on an existing profile keeps its data and refreshes the icon and shortcuts.
    .EXAMPLE
    New-ChatGPTProfile -Name work -Label Work -Color Blue
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [string]$Label,
        [ValidateSet('Orange', 'Blue', 'Green', 'Purple', 'Red', 'Teal', 'Pink', 'Gray')][string]$Color,
        [string]$Root = (Get-DefaultProfileRoot),
        [switch]$NoDesktopShortcut,
        [switch]$NoStartMenuShortcut
    )
    $layout = Get-ProfileLayout -Name $Name -Root $Root
    $app = Get-ChatGPTPackage
    $meta = Read-ProfileMeta -Layout $layout
    if (-not $Label) { $Label = Get-MetaValue -Meta $meta -Key 'label' -Default $Name }
    if (-not $Color) { $Color = Get-MetaValue -Meta $meta -Key 'color' -Default (Get-NextColor -Root $layout.Root) }
    if (-not $script:Palette.Contains($Color)) { $Color = 'Orange' }

    if (-not $PSCmdlet.ShouldProcess($layout.Dir, 'Create or update ChatGPT profile')) { return }

    Initialize-ProfileFolder -Layout $layout
    $icon = Save-ProfileIcon -App $app -Layout $layout -ColorHex $script:Palette[$Color]
    $folders = @(Get-ShortcutFolder -Desktop:(-not $NoDesktopShortcut) -StartMenu:(-not $NoStartMenuShortcut))
    $created = @(foreach ($folder in $folders) { Save-ProfileShortcut -Layout $layout -Label $Label -Folder $folder -Icon $icon })
    # Shortcuts made earlier (under another label, or in a folder skipped this time) get the new icon too.
    $known = @(Get-MetaValue -Meta $meta -Key 'shortcuts' -Default @())
    foreach ($link in $known) {
        if ($created -notcontains $link -and $link -like '*.lnk' -and (Test-Path -LiteralPath $link)) {
            Write-ShortcutIcon -Path $link -Icon $icon
        }
    }
    Get-ChildItem -LiteralPath $layout.Dir -Filter 'icon*.ico' -File |
        Where-Object { $_.Name -match '^icon(-[0-9a-f]+)?\.ico$' -and $_.FullName -ne $icon } |
        Remove-Item -Force
    # Remember every shortcut ever made for this profile so Remove can clean them all up.
    $shortcuts = @($known + $created | Sort-Object -Unique)
    Save-ProfileMeta -Layout $layout -Meta ([ordered]@{
            name      = $Name
            label     = $Label
            color     = $Color
            created   = Get-MetaValue -Meta $meta -Key 'created' -Default ((Get-Date).ToString('o'))
            shortcuts = $shortcuts
        })
    Write-ProfileLog -Layout $layout -Message "profile created or updated (label '$Label')"
    Get-ChatGPTProfile -Name $Name -Root $layout.Root
}

function Start-ChatGPTProfile {
    <#
    .SYNOPSIS
    Starts ChatGPT with a profile's own login and data, next to any other instance.
    .DESCRIPTION
    If the profile is already running, its window is brought forward. Otherwise the app
    is started inside its Store package with the profile's CODEX_HOME and window data
    folder, and the command waits until the app writes to that CODEX_HOME. If it does
    not within -VerifySeconds, the instance is closed and an error is thrown, because it
    could otherwise be using another account's login.
    .EXAMPLE
    Start-ChatGPTProfile work
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [string]$Root = (Get-DefaultProfileRoot),
        [ValidateRange(1, 600)][int]$VerifySeconds = 45
    )
    $layout = Get-ProfileLayout -Name $Name -Root $Root
    if (-not (Test-Path -LiteralPath $layout.CodexHome)) {
        throw "Profile '$Name' does not exist in $($layout.Root). Create it first: chatgpt-profile new $Name"
    }
    $app = Get-ChatGPTPackage
    if (-not $PSCmdlet.ShouldProcess("ChatGPT profile '$Name'", 'Start')) { return }

    Initialize-ProfileFolder -Layout $layout
    # Rewritten on every launch because the app's install folder changes with each update.
    Set-Content -LiteralPath $layout.LaunchCmd -Encoding Ascii -Value (Get-LaunchScriptLine -Layout $layout -Exe $app.Exe)

    $alreadyRunning = @(Get-ProfileProcess -Layout $layout).Count -gt 0
    $started = Get-Date
    Invoke-InPackage -FamilyName $app.FamilyName -ScriptPath $layout.LaunchCmd
    Write-ProfileLog -Layout $layout -Message "launch requested (app $($app.Version), already running: $alreadyRunning)"
    if ($alreadyRunning) {
        # Same data folder, so the running instance just comes to the front.
        return [pscustomobject]@{ Name = $Name; Status = 'AlreadyRunning' }
    }

    $deadline = $started.AddSeconds($VerifySeconds)
    while (-not (Test-FreshWrite -Path $layout.CodexHome -Since $started)) {
        if ((Get-Date) -gt $deadline) {
            $null = Close-ProfileProcess -Layout $layout
            $message = "ChatGPT did not start using this profile's data folder within $VerifySeconds seconds, " +
                "so it was closed to avoid sharing another account's login. An app update may have changed " +
                "how this works; run 'chatgpt-profile doctor -Deep'. Log: $($layout.Log)"
            Write-ProfileLog -Layout $layout -Message "ERROR: $message"
            throw $message
        }
        Start-Sleep -Milliseconds 500
    }
    Write-ProfileLog -Layout $layout -Message "verified: app is using $($layout.CodexHome)"
    [pscustomobject]@{ Name = $Name; Status = 'Started' }
}

function Stop-ChatGPTProfile {
    <#
    .SYNOPSIS
    Ends a profile's ChatGPT instance and everything it started.
    .DESCRIPTION
    Works like End task in Task Manager. Closing ChatGPT's window only hides it to the
    system tray; to quit normally, use Quit in the tray icon's menu instead.
    .EXAMPLE
    Stop-ChatGPTProfile work
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [string]$Root = (Get-DefaultProfileRoot)
    )
    $layout = Get-ProfileLayout -Name $Name -Root $Root
    if (@(Get-ProfileProcess -Layout $layout).Count -eq 0) {
        Write-Verbose "Profile '$Name' is not running."
        return
    }
    if ($PSCmdlet.ShouldProcess("ChatGPT profile '$Name'", 'Stop')) {
        $null = Close-ProfileProcess -Layout $layout
        Write-ProfileLog -Layout $layout -Message 'stopped'
    }
}

function Get-ChatGPTProfile {
    <#
    .SYNOPSIS
    Lists profiles, whether each is running and whether it has a saved login.
    .EXAMPLE
    Get-ChatGPTProfile
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][SupportsWildcards()][string]$Name = '*',
        [string]$Root = (Get-DefaultProfileRoot)
    )
    $rootPath = Resolve-ProfileRoot -Root $Root
    if (-not (Test-Path -LiteralPath $rootPath)) { return }
    $running = @(Get-ChatGPTMainProcess)
    Get-ChildItem -LiteralPath $rootPath -Directory |
        Where-Object {
            $_.Name -like $Name -and $_.Name -match $script:NamePattern -and
            (Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'codex-home'))
        } |
        ForEach-Object {
            $layout = Get-ProfileLayout -Name $_.Name -Root $rootPath
            $meta = Read-ProfileMeta -Layout $layout
            $proc = @(Get-ProfileProcess -Layout $layout -Process $running)
            $processId = $null
            if ($proc.Count -gt 0) { $processId = [int]$proc[0].ProcessId }
            [pscustomobject]@{
                Name      = $layout.Name
                Label     = Get-MetaValue -Meta $meta -Key 'label' -Default $layout.Name
                Running   = $proc.Count -gt 0
                ProcessId = $processId
                SignedIn  = Test-Path -LiteralPath (Join-Path -Path $layout.CodexHome -ChildPath 'auth.json')
                Path      = $layout.Dir
            }
        }
}

function Remove-ChatGPTProfile {
    <#
    .SYNOPSIS
    Removes a profile's shortcuts and, unless -KeepData, its folder including its login.
    .EXAMPLE
    Remove-ChatGPTProfile work
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [string]$Root = (Get-DefaultProfileRoot),
        [switch]$KeepData
    )
    $layout = Get-ProfileLayout -Name $Name -Root $Root
    if (-not (Test-Path -LiteralPath $layout.Dir)) { throw "Profile '$Name' does not exist in $($layout.Root)." }
    $item = Get-Item -LiteralPath $layout.Dir -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to remove '$($layout.Dir)' because it is a link to another folder."
    }
    $action = 'Remove profile, including its login and all its data'
    if ($KeepData) { $action = 'Remove profile shortcuts (keep data)' }
    if (-not $PSCmdlet.ShouldProcess($layout.Dir, $action)) { return }

    $meta = Read-ProfileMeta -Layout $layout
    foreach ($link in @(Get-MetaValue -Meta $meta -Key 'shortcuts' -Default @())) {
        if ($link -like '*.lnk' -and (Test-Path -LiteralPath $link)) { Remove-Item -LiteralPath $link -Force }
    }
    if ($KeepData) { return }

    $null = Close-ProfileProcess -Layout $layout
    # rmdir /s deletes links inside the folder without following them into their targets.
    # Start-Process passes the quoted path verbatim, so characters like & stay literal.
    $cmd = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe'
    Start-Process -FilePath $cmd -ArgumentList ('/d /c rmdir /s /q "' + $layout.Dir + '"') -Wait -WindowStyle Hidden
    if (Test-Path -LiteralPath $layout.Dir) {
        throw "Could not fully remove '$($layout.Dir)'. Close anything using it and try again."
    }
}

function Test-ChatGPTProfileSupport {
    <#
    .SYNOPSIS
    Checks that this machine and the installed app version support side-by-side profiles.
    .DESCRIPTION
    -Deep also scans the app bundle (about 600 MB, a few seconds) to confirm the app
    still reads the two environment variables this tool relies on.
    .EXAMPLE
    Test-ChatGPTProfileSupport -Deep
    #>
    [CmdletBinding()]
    param(
        [string]$Root = (Get-DefaultProfileRoot),
        [switch]$Deep
    )
    $app = $null
    try {
        $app = Get-ChatGPTPackage
        Get-CheckResult -Check 'ChatGPT app' -Status 'OK' -Detail "version $($app.Version)"
    } catch {
        Get-CheckResult -Check 'ChatGPT app' -Status 'FAIL' -Detail $_.Exception.Message
    }

    if (Get-Command -Name Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue) {
        Get-CheckResult -Check 'In-package launch' -Status 'OK' -Detail 'Invoke-CommandInDesktopPackage is available'
    } else {
        Get-CheckResult -Check 'In-package launch' -Status 'FAIL' -Detail 'Invoke-CommandInDesktopPackage is missing. Run from Windows PowerShell 5.1 on Windows 10 1809 or later.'
    }

    try {
        $rootPath = Resolve-ProfileRoot -Root $Root
        Get-CheckResult -Check 'Profile folder' -Status 'OK' -Detail $rootPath
    } catch {
        Get-CheckResult -Check 'Profile folder' -Status 'FAIL' -Detail $_.Exception.Message
    }

    if (-not $Deep) {
        Get-CheckResult -Check 'App support' -Status 'SKIP' -Detail 'Add -Deep to scan the app bundle for the variables this tool uses.'
    } elseif ($null -eq $app -or -not (Test-Path -LiteralPath $app.Bundle)) {
        Get-CheckResult -Check 'App support' -Status 'FAIL' -Detail 'App bundle not found.'
    } else {
        $found = Test-FileContainsText -Path $app.Bundle -Text $script:EnvVarNames
        $missing = @($found.Keys | Where-Object { -not $found[$_] })
        if ($missing.Count -eq 0) {
            Get-CheckResult -Check 'App support' -Status 'OK' -Detail ('app still reads ' + ($script:EnvVarNames -join ' and '))
        } else {
            Get-CheckResult -Check 'App support' -Status 'FAIL' -Detail ("this app version no longer mentions $($missing -join ', '); " +
                'launches will likely be stopped by the safety check')
        }
    }
}

#endregion

Export-ModuleMember -Function New-ChatGPTProfile, Start-ChatGPTProfile, Stop-ChatGPTProfile, Get-ChatGPTProfile, Remove-ChatGPTProfile, Test-ChatGPTProfileSupport
