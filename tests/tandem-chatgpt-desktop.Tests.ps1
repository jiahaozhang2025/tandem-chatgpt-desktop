#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Tests use temporary profiles/shortcuts and an invisible native test window.
# Package lookups, process lookups and in-package launches are mocked.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\tandem-chatgpt-desktop\tandem-chatgpt-desktop.psd1') -Force
    Mock -ModuleName tandem-chatgpt-desktop Start-ProfileTaskbarHelper { }
    Add-Type -AssemblyName System.Drawing

    function New-TestPng([int]$Size) {
        $bitmap = New-Object System.Drawing.Bitmap $Size, $Size
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::SeaGreen)
        $graphics.Dispose()
        $stream = New-Object IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
        , $stream.ToArray()
    }

    # A white circle or square on a transparent background, like the app's flat logos.
    function New-TestLogo([int]$Size, [string]$Shape) {
        $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        if ($Shape -eq 'circle') {
            $graphics.FillEllipse([System.Drawing.Brushes]::White, [int]($Size / 8), [int]($Size / 8), [int]($Size * 3 / 4), [int]($Size * 3 / 4))
        } else {
            $graphics.FillRectangle([System.Drawing.Brushes]::White, 0, 0, $Size, $Size)
        }
        $graphics.Dispose()
        $stream = New-Object IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
        , $stream.ToArray()
    }

    # The frames of an .ico file, as size -> PNG bytes.
    function Get-IcoFrame([string]$Path) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $frames = @{}
        for ($i = 0; $i -lt [BitConverter]::ToUInt16($bytes, 4); $i++) {
            $entry = 6 + 16 * $i
            $size = [int]$bytes[$entry]
            if ($size -eq 0) { $size = 256 }
            $length = [int][BitConverter]::ToUInt32($bytes, $entry + 8)
            $offset = [int][BitConverter]::ToUInt32($bytes, $entry + 12)
            $png = New-Object byte[] $length
            [Array]::Copy($bytes, $offset, $png, 0, $length)
            $frames[$size] = $png
        }
        $frames
    }

    function Get-PngPixel([byte[]]$Png, [int]$X, [int]$Y) {
        $stream = New-Object IO.MemoryStream (, $Png)
        $bitmap = New-Object System.Drawing.Bitmap $stream
        try { $bitmap.GetPixel($X, $Y) } finally { $bitmap.Dispose(); $stream.Dispose() }
    }

    function New-FakePackage {
        $drive = (Get-PSDrive TestDrive).Root
        [pscustomobject]@{
            Version    = '26.1.0.0'
            FamilyName = 'OpenAI.Codex_test'
            Exe        = 'C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe'
            BaseIcon   = Join-Path $drive 'base.ico'
            Assets     = Join-Path $drive 'assets'
            Bundle     = Join-Path $drive 'app.asar'
        }
    }

    function New-TestProfileFolder([string]$Root, [string]$Name) {
        $dir = Join-Path $Root $Name
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'codex-home'), (Join-Path $dir 'electron')
        $dir
    }
}

Describe 'Profile names and roots' {
    It 'accepts the name <_>' -ForEach @('a', 'account2', 'Work_1', 'x-y', ('a' * 64)) {
        InModuleScope tandem-chatgpt-desktop -Parameters @{ N = $_ } {
            param($N)
            { Assert-ProfileName -Name $N } | Should -Not -Throw
        }
    }

    It 'rejects the name <_>' -ForEach @('', '-x', '_x', 'a b', '..', 'a\b', 'a/b', 'a.b', ('a' * 65)) {
        InModuleScope tandem-chatgpt-desktop -Parameters @{ N = $_ } {
            param($N)
            { Assert-ProfileName -Name $N } | Should -Throw '*Invalid profile name*'
        }
    }

    It 'rejects a root with non-ASCII characters' {
        InModuleScope tandem-chatgpt-desktop {
            { Resolve-ProfileRoot -Root ('C:\Users\Jos' + [char]0xE9 + '\tandem-chatgpt-desktop') } | Should -Throw '*non-ASCII*'
        }
    }

    It 'rejects a root containing %' {
        InModuleScope tandem-chatgpt-desktop { { Resolve-ProfileRoot -Root 'C:\100%\profiles' } | Should -Throw "*'%'*" }
    }

    It 'rejects a drive root' {
        InModuleScope tandem-chatgpt-desktop { { Resolve-ProfileRoot -Root 'C:\' } | Should -Throw '*drive root*' }
    }

    It 'trims a trailing backslash' {
        InModuleScope tandem-chatgpt-desktop { Resolve-ProfileRoot -Root 'C:\Profiles\' | Should -Be 'C:\Profiles' }
    }
}

Describe 'Get-ProfileLayout' {
    It 'keeps everything under <root>\<name>' {
        InModuleScope tandem-chatgpt-desktop {
            $layout = Get-ProfileLayout -Name 'work' -Root 'C:\P'
            $layout.Dir | Should -Be 'C:\P\work'
            $layout.CodexHome | Should -Be 'C:\P\work\codex-home'
            $layout.UserData | Should -Be 'C:\P\work\electron'
            $layout.UserDataArg | Should -Be '--user-data-dir="C:\P\work\electron"'
            $layout.Config | Should -Be 'C:\P\work\codex-home\config.toml'
        }
    }
}

Describe 'Get-LaunchScriptLine' {
    It 'sets both variables and starts the app with the profile data folder' {
        InModuleScope tandem-chatgpt-desktop {
            $layout = Get-ProfileLayout -Name 'work' -Root 'C:\P'
            $lines = Get-LaunchScriptLine -Layout $layout -Exe 'C:\Program Files\WindowsApps\Pkg\app\ChatGPT.exe'
            $lines | Should -Be @(
                '@echo off'
                'set "CODEX_HOME=C:\P\work\codex-home"'
                'set "CODEX_ELECTRON_USER_DATA_PATH=C:\P\work\electron"'
                'start "" "C:\Program Files\WindowsApps\Pkg\app\ChatGPT.exe" --user-data-dir="C:\P\work\electron"'
            )
        }
    }
}

Describe 'Process matching' {
    It 'matches only the main process of the requested profile' {
        $procs = @(
            [pscustomobject]@{ ProcessId = 1; CommandLine = '"C:\App\ChatGPT.exe" --user-data-dir="C:\P\account2\electron"' }
            [pscustomobject]@{ ProcessId = 2; CommandLine = '"C:\App\ChatGPT.exe" --user-data-dir="C:\P\account22\electron"' }
            [pscustomobject]@{ ProcessId = 3; CommandLine = '"C:\App\ChatGPT.exe"' }
        )
        InModuleScope tandem-chatgpt-desktop -Parameters @{ Procs = $procs } {
            param($Procs)
            $layout = Get-ProfileLayout -Name 'account2' -Root 'C:\P'
            @(Get-ProfileProcess -Layout $layout -Process $Procs).ProcessId | Should -Be @(1)
        }
    }

    It 'ignores differences in letter case' {
        $procs = @([pscustomobject]@{ ProcessId = 9; CommandLine = '"ChatGPT.exe" --user-data-dir="c:\p\WORK\electron"' })
        InModuleScope tandem-chatgpt-desktop -Parameters @{ Procs = $procs } {
            param($Procs)
            $layout = Get-ProfileLayout -Name 'work' -Root 'C:\P'
            @(Get-ProfileProcess -Layout $layout -Process $Procs).Count | Should -Be 1
        }
    }

    It 'skips Electron helper processes' {
        Mock -ModuleName tandem-chatgpt-desktop Get-CimInstance {
            [pscustomobject]@{ ProcessId = 1; CommandLine = '"ChatGPT.exe" --user-data-dir="C:\P\w\electron"' }
            [pscustomobject]@{ ProcessId = 2; CommandLine = '"ChatGPT.exe" --type=renderer --user-data-dir="C:\P\w\electron"' }
            [pscustomobject]@{ ProcessId = 3; CommandLine = $null }
        }
        InModuleScope tandem-chatgpt-desktop { @(Get-ChatGPTMainProcess).ProcessId | Should -Be @(1) }
    }
}

Describe 'Start-ChatGPTProfile' {
    BeforeEach {
        Mock -ModuleName tandem-chatgpt-desktop Test-DesktopWindow { $true }
        $root = Join-Path $TestDrive 'profiles'
        $null = New-TestProfileFolder -Root $root -Name 'work'
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage { New-FakePackage }
        Mock -ModuleName tandem-chatgpt-desktop Get-ProfileProcess { }
        Mock -ModuleName tandem-chatgpt-desktop Close-ProfileProcess { 1 }
    }

    It 'throws for a profile that does not exist' {
        { Start-ChatGPTProfile -Name 'nope' -Root $root } | Should -Throw '*does not exist*'
    }

    It 'launches inside the package and confirms the profile CODEX_HOME is used' {
        Mock -ModuleName tandem-chatgpt-desktop Invoke-InPackage {
            Set-Content -LiteralPath (Join-Path (Split-Path $ScriptPath) 'codex-home\state_5.sqlite') -Value 'x'
        }
        $result = Start-ChatGPTProfile -Name 'work' -Root $root -VerifySeconds 10

        $result.Status | Should -Be 'Started'
        Should -Invoke -ModuleName tandem-chatgpt-desktop Invoke-InPackage -Times 1 -Exactly -ParameterFilter {
            $FamilyName -eq 'OpenAI.Codex_test' -and $ScriptPath -like '*\profiles\work\launch.cmd'
        }
        Should -Invoke -ModuleName tandem-chatgpt-desktop Close-ProfileProcess -Times 0
        $cmd = Get-Content -LiteralPath (Join-Path $root 'work\launch.cmd')
        $cmd[1] | Should -Be ('set "CODEX_HOME=' + (Join-Path $root 'work\codex-home') + '"')
        $cmd[3] | Should -BeLike 'start "" "C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe" --user-data-dir=*'
        Get-Content -LiteralPath (Join-Path $root 'work\codex-home\config.toml') | Should -Be 'cli_auth_credentials_store = "file"'
        Get-Content -LiteralPath (Join-Path $root 'work\launcher.log') -Raw | Should -BeLike '*verified*'
    }

    It 'closes the instance and throws when the profile CODEX_HOME stays untouched' {
        Mock -ModuleName tandem-chatgpt-desktop Invoke-InPackage { }
        { Start-ChatGPTProfile -Name 'work' -Root $root -VerifySeconds 1 } | Should -Throw '*did not start using*'
        Should -Invoke -ModuleName tandem-chatgpt-desktop Close-ProfileProcess -Times 1 -Exactly
        Get-Content -LiteralPath (Join-Path $root 'work\launcher.log') -Raw | Should -BeLike '*ERROR*'
    }

    It 'only brings the window forward when the profile is already running' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ProfileProcess { [pscustomobject]@{ ProcessId = 42; CommandLine = 'x' } }
        Mock -ModuleName tandem-chatgpt-desktop Invoke-InPackage { }
        Mock -ModuleName tandem-chatgpt-desktop Test-FreshWrite { $false }

        (Start-ChatGPTProfile -Name 'work' -Root $root).Status | Should -Be 'AlreadyRunning'
        Should -Invoke -ModuleName tandem-chatgpt-desktop Invoke-InPackage -Times 1 -Exactly
        Should -Invoke -ModuleName tandem-chatgpt-desktop Test-FreshWrite -Times 0
    }
    It 'does not report success from profile writes alone while its window stays hidden' {
        Mock -ModuleName tandem-chatgpt-desktop Invoke-InPackage { }
        Mock -ModuleName tandem-chatgpt-desktop Test-FreshWrite { $true }
        Mock -ModuleName tandem-chatgpt-desktop Test-DesktopWindow { $false }
        { Start-ChatGPTProfile -Name work -Root $root -VerifySeconds 1 } | Should -Throw '*no visible account window*No processes were stopped*'
        Should -Invoke -ModuleName tandem-chatgpt-desktop Close-ProfileProcess -Times 0
    }
}

Describe 'New-ChatGPTProfile' {
    BeforeAll {
        $drive = (Get-PSDrive TestDrive).Root
        # The window icon, used only when the app ships no flat logo: a fully opaque square.
        $png = New-TestPng 256
        InModuleScope tandem-chatgpt-desktop -Parameters @{ Png = $png; Path = (Join-Path $drive 'base.ico') } {
            param($Png, $Path)
            [IO.File]::WriteAllBytes($Path, (ConvertTo-IcoByte -Frame @([pscustomobject]@{ Size = 256; Bytes = $Png })))
        }
        # The app's flat logos: a circle at 256 px and a square at 16 px, so a frame shows
        # which file it came from, plus a light-theme variant that must be ignored.
        $assets = Join-Path $drive 'assets'
        $null = New-Item -ItemType Directory -Force -Path $assets
        [IO.File]::WriteAllBytes((Join-Path $assets 'Square44x44Logo.targetsize-256_altform-unplated.png'), (New-TestLogo 256 'circle'))
        [IO.File]::WriteAllBytes((Join-Path $assets 'Square44x44Logo.targetsize-16_altform-unplated.png'), (New-TestLogo 16 'square'))
        [IO.File]::WriteAllBytes((Join-Path $assets 'Square44x44Logo.targetsize-256_altform-lightunplated.png'), (New-TestLogo 256 'square'))
    }

    BeforeEach {
        $root = Join-Path $TestDrive 'profiles'
        $desktop = Join-Path $TestDrive 'desktop'
        $startMenu = Join-Path $TestDrive 'startmenu'
        $null = New-Item -ItemType Directory -Force -Path $desktop, $startMenu
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage { New-FakePackage }
        Mock -ModuleName tandem-chatgpt-desktop Get-ShortcutFolder {
            $drive = (Get-PSDrive TestDrive).Root
            if ($Desktop) { Join-Path $drive 'desktop' }
            if ($StartMenu) { Join-Path $drive 'startmenu' }
        }
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTMainProcess { }
    }

    AfterEach {
        Remove-Item -LiteralPath $root, $desktop, $startMenu -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates the folders, login config, metadata, icon and both shortcuts' {
        $result = New-ChatGPTProfile -Name 'work' -Label 'Work' -Color 'Blue' -Root $root -Confirm:$false

        $result.Name | Should -Be 'work'
        $result.Label | Should -Be 'Work'
        $result.SignedIn | Should -BeFalse
        Join-Path $root 'work\electron' | Should -Exist
        Get-Content -LiteralPath (Join-Path $root 'work\codex-home\config.toml') | Should -Be 'cli_auth_credentials_store = "file"'

        $meta = Get-Content -LiteralPath (Join-Path $root 'work\profile.json') -Raw | ConvertFrom-Json
        $meta.label | Should -Be 'Work'
        $meta.color | Should -Be 'Blue'
        $meta.PSObject.Properties.Name | Should -Not -Contain 'badge'

        $icons = @(Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'icon*.ico')
        $icons.Count | Should -Be 1
        $icons[0].Name | Should -Match '^icon-[0-9a-f]{8}\.ico$'
        $bytes = [IO.File]::ReadAllBytes($icons[0].FullName)
        $bytes[0..3] | Should -Be @(0, 0, 1, 0)
        [BitConverter]::ToUInt16($bytes, 4) | Should -Be 5

        foreach ($folder in $desktop, $startMenu) {
            $lnkPath = Join-Path $folder 'ChatGPT (Work).lnk'
            $lnkPath | Should -Exist
            $link = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
            $link.TargetPath | Should -BeLike '*\WindowsPowerShell\v1.0\powershell.exe'
            $link.Arguments | Should -BeLike ('*chatgpt-profile.ps1" launch work -Root "' + $root + '" -Gui')
            $link.IconLocation | Should -BeLike ('*\work\' + $icons[0].Name + ',0')
        }
        @($meta.shortcuts).Count | Should -Be 2
    }

    It 'colors the flat logo, keeps its transparency and prefers the exact-size logo' {
        $null = New-ChatGPTProfile -Name 'work' -Color 'Blue' -Root $root -NoDesktopShortcut -NoStartMenuShortcut -Confirm:$false
        $frames = Get-IcoFrame (Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'icon-*.ico').FullName

        @($frames.Keys | Sort-Object) | Should -Be @(16, 24, 32, 48, 256)
        # Palette Blue is #1C7ED6.
        $center = Get-PngPixel $frames[256] 128 128
        $center.A | Should -Be 255
        [Math]::Abs($center.R - 0x1C) | Should -BeLessOrEqual 1
        [Math]::Abs($center.G - 0x7E) | Should -BeLessOrEqual 1
        [Math]::Abs($center.B - 0xD6) | Should -BeLessOrEqual 1
        # The circle's corners stay transparent, so the light-theme square was not used.
        (Get-PngPixel $frames[256] 2 2).A | Should -Be 0
        # 16 px comes from the 16 px square; 32 px has no own logo and is scaled from the circle.
        (Get-PngPixel $frames[16] 1 1).A | Should -BeGreaterThan 240
        (Get-PngPixel $frames[32] 1 1).A | Should -Be 0
    }

    It 'keeps existing data and settings when run again' {
        $null = New-ChatGPTProfile -Name 'work' -Label 'Work' -Color 'Green' -Root $root -Confirm:$false
        Set-Content -LiteralPath (Join-Path $root 'work\codex-home\auth.json') -Value '{}'
        $created = (Get-Content -LiteralPath (Join-Path $root 'work\profile.json') -Raw | ConvertFrom-Json).created

        $result = New-ChatGPTProfile -Name 'work' -Root $root -Confirm:$false

        $result.SignedIn | Should -BeTrue
        $meta = Get-Content -LiteralPath (Join-Path $root 'work\profile.json') -Raw | ConvertFrom-Json
        $meta.label | Should -Be 'Work'
        $meta.color | Should -Be 'Green'
        $meta.created | Should -Be $created
        @(Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'icon*.ico').Count | Should -Be 1
    }

    It 'gives a changed icon a new file name and points older shortcuts at it' {
        $null = New-ChatGPTProfile -Name 'work' -Label 'Work' -Color 'Green' -Root $root -Confirm:$false
        $old = (Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'icon-*.ico').Name
        Set-Content -LiteralPath (Join-Path $root 'work\icon.ico') -Value 'icon file from 0.1.x'

        $null = New-ChatGPTProfile -Name 'work' -Color 'Red' -Root $root -NoStartMenuShortcut -Confirm:$false

        $icons = @(Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'icon*.ico')
        $icons.Count | Should -Be 3
        Join-Path $root ('work\' + $old) | Should -Exist
        $meta = Get-Content (Join-Path $root 'work\profile.json') -Raw | ConvertFrom-Json
        (Split-Path $meta.icon -Leaf) | Should -Not -Be $old
        # The Start menu shortcut was not recreated this time, but it uses the new icon too.
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startMenu 'ChatGPT (Work).lnk'))
        $link.IconLocation | Should -BeLike ($meta.icon + ',0')
    }

    It 'skips both shortcuts on request' {
        $null = New-ChatGPTProfile -Name 'work' -Root $root -NoDesktopShortcut -NoStartMenuShortcut -Confirm:$false
        @(Get-ChildItem -LiteralPath $desktop, $startMenu -Filter '*.lnk').Count | Should -Be 0
    }

    It 'falls back to the window icon when the app ships no flat logo' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage {
            $package = New-FakePackage
            $package.Assets = Join-Path (Get-PSDrive TestDrive).Root 'no-assets'
            $package
        }
        $null = New-ChatGPTProfile -Name 'work' -Color 'Blue' -Root $root -NoDesktopShortcut -NoStartMenuShortcut -Confirm:$false
        $frames = Get-IcoFrame (Get-ChildItem -LiteralPath (Join-Path $root 'work') -Filter 'icon-*.ico').FullName
        $pixel = Get-PngPixel $frames[256] 128 128
        $pixel.A | Should -Be 255
        [Math]::Abs($pixel.B - 0xD6) | Should -BeLessOrEqual 1
    }
}

Describe 'Get-ChatGPTProfile' {
    BeforeAll {
        $root = Join-Path $TestDrive 'profiles'
        $work = New-TestProfileFolder -Root $root -Name 'work'
        Set-Content -LiteralPath (Join-Path $work 'codex-home\auth.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $work 'profile.json') -Value '{ "label": "Work" }'
        $null = New-TestProfileFolder -Root $root -Name 'idle'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'not-a-profile')
        Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Value 'x'
    }

    BeforeEach {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTMainProcess {
            $electron = Join-Path (Get-PSDrive TestDrive).Root 'profiles\work\electron'
            [pscustomobject]@{ ProcessId = 7; CommandLine = '"ChatGPT.exe" --user-data-dir="' + $electron + '"' }
        }
    }

    It 'lists only profile folders, with running and sign-in state' {
        $all = @(Get-ChatGPTProfile -Root $root | Sort-Object Name)
        $all.Name | Should -Be @('idle', 'work')
        $all[1].Label | Should -Be 'Work'
        $all[1].Running | Should -BeTrue
        $all[1].ProcessId | Should -Be 7
        $all[1].SignedIn | Should -BeTrue
        $all[0].Running | Should -BeFalse
        $all[0].SignedIn | Should -BeFalse
    }

    It 'filters by name with wildcards' {
        @(Get-ChatGPTProfile -Name 'w*' -Root $root).Name | Should -Be @('work')
    }

    It 'returns nothing when the root does not exist' {
        @(Get-ChatGPTProfile -Root (Join-Path $TestDrive 'missing')).Count | Should -Be 0
    }
}

Describe 'Remove-ChatGPTProfile' {
    BeforeEach {
        $root = Join-Path $TestDrive 'profiles'
        $dir = New-TestProfileFolder -Root $root -Name 'work'
        $lnk = Join-Path $TestDrive 'ChatGPT (Work).lnk'
        Set-Content -LiteralPath $lnk -Value 'x'
        @{ label = 'Work'; shortcuts = @($lnk) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'profile.json')
        Mock -ModuleName tandem-chatgpt-desktop Close-ProfileProcess { 0 }
    }

    AfterEach {
        Get-ChildItem -LiteralPath $TestDrive -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
            ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'removes the folder and its shortcuts' {
        Remove-ChatGPTProfile -Name 'work' -Root $root -Confirm:$false
        $dir | Should -Not -Exist
        $lnk | Should -Not -Exist
        Should -Invoke -ModuleName tandem-chatgpt-desktop Close-ProfileProcess -Times 1 -Exactly
    }

    It 'keeps the data with -KeepData' {
        Remove-ChatGPTProfile -Name 'work' -Root $root -KeepData -Confirm:$false
        $dir | Should -Exist
        $lnk | Should -Not -Exist
        Should -Invoke -ModuleName tandem-chatgpt-desktop Close-ProfileProcess -Times 0
    }

    It 'does not follow links inside the profile folder' {
        $outside = Join-Path $TestDrive 'outside'
        $null = New-Item -ItemType Directory -Force -Path $outside
        Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'x'
        $null = New-Item -ItemType Junction -Path (Join-Path $dir 'codex-home\linked') -Target $outside

        Remove-ChatGPTProfile -Name 'work' -Root $root -Confirm:$false

        $dir | Should -Not -Exist
        Join-Path $outside 'keep.txt' | Should -Exist
    }

    It 'refuses when the profile folder itself is a link' {
        $real = Join-Path $TestDrive 'real'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $real 'codex-home')
        $null = New-Item -ItemType Junction -Path (Join-Path $root 'linked') -Target $real

        { Remove-ChatGPTProfile -Name 'linked' -Root $root -Confirm:$false } | Should -Throw '*link to another folder*'
        Join-Path $real 'codex-home' | Should -Exist
        [IO.Directory]::Delete((Join-Path $root 'linked'))
    }

    It 'throws for a profile that does not exist' {
        { Remove-ChatGPTProfile -Name 'nope' -Root $root -Confirm:$false } | Should -Throw '*does not exist*'
    }
}

Describe 'Close-ProfileProcess' {
    It 'returns 0 when the profile is not running' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ProfileProcess { }
        InModuleScope tandem-chatgpt-desktop {
            Close-ProfileProcess -Layout (Get-ProfileLayout -Name 'w' -Root 'C:\P') | Should -Be 0
        }
    }

    It 'ends the instance and its whole process tree' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ProfileProcess { [pscustomobject]@{ ProcessId = 101; CommandLine = 'x' } }
        Mock -ModuleName tandem-chatgpt-desktop Get-ProcessTreeId { 103, 102, 101 }
        Mock -ModuleName tandem-chatgpt-desktop Stop-Process { }
        InModuleScope tandem-chatgpt-desktop {
            Close-ProfileProcess -Layout (Get-ProfileLayout -Name 'w' -Root 'C:\P') | Should -Be 1
        }
        Should -Invoke -ModuleName tandem-chatgpt-desktop Stop-Process -Times 3 -Exactly
        Should -Invoke -ModuleName tandem-chatgpt-desktop Get-ProcessTreeId -Times 1 -Exactly -ParameterFilter { $RootId -contains 101 }
    }
}

Describe 'Icons' {
    It 'round-trips PNG frames and picks the largest one' {
        $small = New-TestPng 16
        $large = New-TestPng 256
        InModuleScope tandem-chatgpt-desktop -Parameters @{ Small = $small; Large = $large } {
            param($Small, $Large)
            $path = Join-Path (Get-PSDrive TestDrive).Root 'frames.ico'
            [IO.File]::WriteAllBytes($path, (ConvertTo-IcoByte -Frame @(
                        [pscustomobject]@{ Size = 16; Bytes = $Small }
                        [pscustomobject]@{ Size = 256; Bytes = $Large }
                    )))
            $frame = Get-IcoPngFrame -Path $path
            $frame.Length | Should -Be $Large.Length
            [Convert]::ToBase64String($frame) | Should -Be ([Convert]::ToBase64String($Large))
        }
    }
}

Describe 'Test-FileContainsText' {
    It 'finds text that spans read chunks' {
        $path = Join-Path $TestDrive 'bundle.bin'
        Set-Content -LiteralPath $path -NoNewline -Encoding Ascii -Value (('x' * 10) + 'CODEX_HOME' + ('y' * 7) + 'CODEX_ELECTRON_USER_DATA_PATH' + 'z')
        InModuleScope tandem-chatgpt-desktop -Parameters @{ P = $path } {
            param($P)
            $found = Test-FileContainsText -Path $P -Text 'CODEX_HOME', 'CODEX_ELECTRON_USER_DATA_PATH' -ChunkSize 16
            $found['CODEX_HOME'] | Should -BeTrue
            $found['CODEX_ELECTRON_USER_DATA_PATH'] | Should -BeTrue
        }
    }

    It 'reports text that is missing' {
        $path = Join-Path $TestDrive 'bundle2.bin'
        Set-Content -LiteralPath $path -NoNewline -Encoding Ascii -Value 'only CODEX_HOME here'
        InModuleScope tandem-chatgpt-desktop -Parameters @{ P = $path } {
            param($P)
            $found = Test-FileContainsText -Path $P -Text 'CODEX_HOME', 'CODEX_ELECTRON_USER_DATA_PATH' -ChunkSize 16
            $found['CODEX_HOME'] | Should -BeTrue
            $found['CODEX_ELECTRON_USER_DATA_PATH'] | Should -BeFalse
        }
    }
}

Describe 'Test-ChatGPTProfileSupport' {
    BeforeEach {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage { New-FakePackage }
    }

    It 'confirms app support with -Deep when the bundle reads both variables' {
        Set-Content -LiteralPath (Join-Path $TestDrive 'app.asar') -Encoding Ascii -Value 'a CODEX_HOME b CODEX_ELECTRON_USER_DATA_PATH c'
        $check = Test-ChatGPTProfileSupport -Deep -Root (Join-Path $TestDrive 'profiles') | Where-Object Check -EQ 'App support'
        $check.Status | Should -Be 'OK'
    }

    It 'fails app support when the bundle no longer mentions a variable' {
        Set-Content -LiteralPath (Join-Path $TestDrive 'app.asar') -Encoding Ascii -Value 'a CODEX_HOME b'
        $check = Test-ChatGPTProfileSupport -Deep -Root (Join-Path $TestDrive 'profiles') | Where-Object Check -EQ 'App support'
        $check.Status | Should -Be 'FAIL'
        $check.Detail | Should -BeLike '*CODEX_ELECTRON_USER_DATA_PATH*'
    }

    It 'reports a missing app instead of throwing' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage { throw 'not installed' }
        $results = Test-ChatGPTProfileSupport -Root (Join-Path $TestDrive 'profiles')
        ($results | Where-Object Check -EQ 'ChatGPT app').Status | Should -Be 'FAIL'
        ($results | Where-Object Check -EQ 'App support').Status | Should -Be 'SKIP'
    }
}

Describe 'install.ps1' {
    BeforeAll {
        # Simulate a downloaded release: copy what the installer needs and mark it as
        # downloaded from the internet, as a browser plus Explorer extraction would.
        $repo = Join-Path $PSScriptRoot '..'
        $src = Join-Path $TestDrive 'download'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $src 'tandem-chatgpt-desktop')
        foreach ($file in 'install.ps1', 'chatgpt-profile.ps1', 'taskbar-helper.ps1', 'taskbar-identity.cs', 'uninstall.ps1', 'README.md', 'CHANGELOG.md', 'VALIDATION.md', 'TROUBLESHOOTING.md', 'LICENSE') {
            Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $src
        }
        Copy-Item -Path (Join-Path $repo 'tandem-chatgpt-desktop\*') -Destination (Join-Path $src 'tandem-chatgpt-desktop')
        Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object {
            Set-Content -LiteralPath $_.FullName -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
        }
        $dest = Join-Path $TestDrive 'installed'
        # Run it the way the README says, in the same PowerShell edition as the tests. The
        # Bypass matters: a marked install.ps1 would not run under RemoteSigned.
        $hostExe = (Get-Process -Id $PID).Path
        $null = & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src 'install.ps1') -Destination $dest -NoAllAccountsShortcut
        $installExit = $LASTEXITCODE
    }

    It 'installs the scripts, module and cmd shim' {
        $installExit | Should -Be 0
        foreach ($file in 'chatgpt-profile.ps1', 'chatgpt-profile.cmd', 'taskbar-helper.ps1', 'taskbar-identity.cs', 'uninstall.ps1', 'README.md', 'CHANGELOG.md', 'VALIDATION.md', 'TROUBLESHOOTING.md', 'LICENSE',
            'tandem-chatgpt-desktop\tandem-chatgpt-desktop.psd1', 'tandem-chatgpt-desktop\tandem-chatgpt-desktop.psm1') {
            Join-Path $dest $file | Should -Exist
        }
        Get-Content -LiteralPath (Join-Path $dest 'chatgpt-profile.cmd') |
            Should -Contain 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0chatgpt-profile.ps1" %*'
    }

    It 'removes the downloaded-from-the-internet mark from installed files' {
        Get-Item -LiteralPath (Join-Path $src 'install.ps1') -Stream Zone.Identifier | Should -Not -BeNullOrEmpty
        $marked = @(Get-ChildItem -LiteralPath $dest -Recurse -File |
                Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue })
        $marked.FullName | Should -BeNullOrEmpty
    }

    It 'leaves a module that imports under a RemoteSigned execution policy' {
        $manifest = Join-Path $dest 'tandem-chatgpt-desktop\tandem-chatgpt-desktop.psd1'
        $count = & $hostExe -NoProfile -ExecutionPolicy RemoteSigned -Command "Import-Module '$manifest' -ErrorAction Stop; (Get-Command -Module tandem-chatgpt-desktop).Count"
        $count | Should -Be '9'
    }
}

Describe 'Taskbar profile identities' {
    It 'does not repurpose an existing managed main profile as the native account' {
        $conflictingRoot = Join-Path $TestDrive 'reserved-name'
        $null = New-Item -ItemType Directory -Path (Join-Path $conflictingRoot 'main') -Force
        '{}' | Set-Content (Join-Path $conflictingRoot 'main\profile.json')
        { Set-ChatGPTProfileTaskbar -Root $conflictingRoot -Mode Separate } | Should -Throw '*conflicts with the native account*'
        Test-Path (Join-Path $conflictingRoot 'taskbar.json') | Should -BeFalse
    }
    It 'persists the selected taskbar mode: <Mode>' -ForEach @(
        @{ Mode = 'Grouped'; ExpectedEnabled = $false }, @{ Mode = 'Separate'; ExpectedEnabled = $true }
    ) {
        Mock -ModuleName tandem-chatgpt-desktop Stop-ProfileTaskbarHelper { }
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage { [pscustomobject]@{} }
        Mock -ModuleName tandem-chatgpt-desktop Save-ProfileIcon { 'synthetic.ico' }
        Mock -ModuleName tandem-chatgpt-desktop Save-MainTaskbarShortcut { }
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTProfile { }
        $result = Set-ChatGPTProfileTaskbar -Root $TestDrive -Mode $Mode
        $result.Mode | Should -Be $Mode
        $config = Get-Content (Join-Path $TestDrive 'taskbar.json') -Raw | ConvertFrom-Json
        $config.mode | Should -Be $Mode
        $config.enabled | Should -Be $ExpectedEnabled
        Should -Invoke -ModuleName tandem-chatgpt-desktop Stop-ProfileTaskbarHelper -Times 1 -Exactly
    }
    It 'keeps Disable as an alias for grouped mode' {
        Mock -ModuleName tandem-chatgpt-desktop Stop-ProfileTaskbarHelper { }
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage { [pscustomobject]@{} }
        Mock -ModuleName tandem-chatgpt-desktop Save-ProfileIcon { 'synthetic.ico' }
        Mock -ModuleName tandem-chatgpt-desktop Save-MainTaskbarShortcut { }
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTProfile { }
        (Set-ChatGPTProfileTaskbar -Root $TestDrive -Disable).Mode | Should -Be 'Grouped'
    }
    It 'rejects invalid modes and leaves configuration untouched under WhatIf' {
        $untouchedRoot = Join-Path $TestDrive 'whatif-taskbar'
        { Set-ChatGPTProfileTaskbar -Root $untouchedRoot -Mode invalid } | Should -Throw
        Set-ChatGPTProfileTaskbar -Root $untouchedRoot -Mode Grouped -WhatIf
        Test-Path (Join-Path $untouchedRoot 'taskbar.json') | Should -BeFalse
    }
    It 'exports the taskbar setup command used by the installed CLI' {
        Get-Command Set-ChatGPTProfileTaskbar -Module tandem-chatgpt-desktop | Should -Not -BeNullOrEmpty
    }
    It 'keeps stable, distinct, case-insensitive identities within the Windows length limit' {
        InModuleScope tandem-chatgpt-desktop {
            $first = Get-TaskbarAppId 'C:\Profiles' account2
            $first | Should -Be (Get-TaskbarAppId 'c:\profiles\' ACCOUNT2)
            $first | Should -Not -Be (Get-TaskbarAppId 'C:\Profiles' main)
            $first | Should -Not -Be (Get-TaskbarAppId 'C:\Other' account2)
            (Get-TaskbarAppId 'C:\Profiles' ('a' * 64)).Length | Should -BeLessOrEqual 128
        }
    }
    It 'uses short, separate account shortcuts for pinned-icon relaunch commands' {
        InModuleScope tandem-chatgpt-desktop -Parameters @{ R = $TestDrive } {
            param($R)
            Get-TaskbarLaunchCommand $R main | Should -BeLike '*explorer.exe*main-launcher\taskbar-launch.lnk*'
            Get-TaskbarLaunchCommand $R account2 | Should -BeLike '*explorer.exe*account2\taskbar-launch.lnk*'
        }
    }
    It 'round-trips a shortcut identity without changing its launch target or arguments' {
        InModuleScope tandem-chatgpt-desktop -Parameters @{ R = $TestDrive } {
            param($R)
            Initialize-TaskbarApi
            $path = Join-Path $R 'test.lnk'
            $shell = New-Object -ComObject WScript.Shell
            try {
                $link = $shell.CreateShortcut($path)
                $link.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
                $link.Arguments = 'synthetic.txt'
                $link.Save()
                [Tandem.ChatGPT.TaskbarIdentity]::SetShortcut($path, 'Tandem.ChatGPT.Test')
                [Tandem.ChatGPT.TaskbarIdentity]::ReadShortcut($path) | Should -Be 'Tandem.ChatGPT.Test'
                $read = $shell.CreateShortcut($path)
                $read.Arguments | Should -Be 'synthetic.txt'
                $read.TargetPath | Should -Be $link.TargetPath
                [Tandem.ChatGPT.TaskbarIdentity]::SetShortcut($path, $null)
                [Tandem.ChatGPT.TaskbarIdentity]::ReadShortcut($path) | Should -BeNullOrEmpty
            } finally { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        }
    }
    It 'sets and restores window identities and relaunch details on an invisible test window' {
        InModuleScope tandem-chatgpt-desktop {
            Initialize-TaskbarApi
            Add-Type -AssemblyName System.Windows.Forms
            $form = New-Object Windows.Forms.Form
            try {
                $handle = $form.Handle
                $original = [Tandem.ChatGPT.TaskbarIdentity]::ReadWindow($handle, 5)
                $iconPath = Join-Path (Get-PSDrive TestDrive).Root 'window-icon.ico'
                $stream = [IO.File]::Create($iconPath)
                try { [Drawing.SystemIcons]::Information.Save($stream) } finally { $stream.Dispose() }
                [Tandem.ChatGPT.TaskbarIdentity]::Apply($handle, 'Tandem.ChatGPT.Test', 'synthetic.exe', 'Synthetic profile', $iconPath)
                [Tandem.ChatGPT.TaskbarIdentity]::ReadWindow($handle, 5) | Should -Be 'Tandem.ChatGPT.Test'
                [Tandem.ChatGPT.TaskbarIdentity]::ReadWindow($handle, 2) | Should -Be 'synthetic.exe'
                [Tandem.ChatGPT.TaskbarIdentity]::ReadWindow($handle, 4) | Should -Be 'Synthetic profile'
                [Tandem.ChatGPT.TaskbarIdentity]::RestoreAll()
                [Tandem.ChatGPT.TaskbarIdentity]::ReadWindow($handle, 5) | Should -Be $original
            } finally { [Tandem.ChatGPT.TaskbarIdentity]::RestoreAll(); $form.Dispose() }
        }
    }
    It 'ignores a reused helper process ID belonging to a different command' {
        InModuleScope tandem-chatgpt-desktop -Parameters @{ R = $TestDrive } {
            param($R)
            '{"pid":123}' | Set-Content -LiteralPath (Join-Path $R 'taskbar-helper.json')
            Mock Get-CimInstance { [pscustomobject]@{ Name = 'powershell.exe'; CommandLine = 'powershell.exe -File unrelated.ps1' } }
            Get-TaskbarHelperProcess $R | Should -BeNullOrEmpty
        }
    }
    It 'does not launch the primary app when WhatIf is requested' {
        Mock -ModuleName tandem-chatgpt-desktop Start-PrimaryChatGPT { }
        Start-ChatGPTProfile main -Root $TestDrive -WhatIf
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-PrimaryChatGPT -Times 0
    }
}

Describe 'Launch all accounts' {
    BeforeEach {
        Mock -ModuleName tandem-chatgpt-desktop Test-DesktopWindow { $true }
        Mock -ModuleName tandem-chatgpt-desktop Stop-Process { }
        $allRoot = Join-Path $TestDrive 'all profiles'
        $null = New-Item -ItemType Directory -Path $allRoot -Force
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTProfile { [pscustomobject]@{ Name = 'account2' } }
        Mock -ModuleName tandem-chatgpt-desktop Get-ProfileLayout { [pscustomobject]@{ Name = $Name; UserData = (Join-Path $Root "$Name\electron"); UserDataArg = ('--user-data-dir="' + (Join-Path $Root "$Name\electron") + '"') } }
        Mock -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile { [pscustomobject]@{ Name = $Name; Status = 'Started' } }
    }

    It 'reactivates a running hidden account instead of skipping it' {
        $script:accountVisible = $false
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTMainProcess {
            [pscustomobject]@{ CommandLine = 'ChatGPT.exe'; ProcessId = 10 }
            [pscustomobject]@{ CommandLine = ('ChatGPT.exe --user-data-dir="' + (Join-Path $allRoot 'account2\electron') + '"'); ProcessId = 20 }
        }
        Mock -ModuleName tandem-chatgpt-desktop Test-DesktopWindow { $Process.Count -gt 0 -and ($Process[0].ProcessId -ne 20 -or $script:accountVisible) }
        Mock -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile { $script:accountVisible = $true; [pscustomobject]@{ Name = $Name; Status = 'AlreadyRunning' } }
        $null = Start-ChatGPTAllAccounts -Root $allRoot -VerifySeconds 1
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 0 -ParameterFilter { $Name -eq 'main' }
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 1 -Exactly -ParameterFilter { $Name -eq 'account2' }
        Get-Content (Join-Path $allRoot 'launcher-events.log') -Raw | Should -BeLike '*"state":"Hidden","action":"Activate"*'
        Should -Invoke -ModuleName tandem-chatgpt-desktop Stop-Process -Times 0
    }
    It 'reports invisible processes as failures without stopping them' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTMainProcess { }
        Mock -ModuleName tandem-chatgpt-desktop Test-DesktopWindow { $false }
        { Start-ChatGPTAllAccounts -Root $allRoot -VerifySeconds 1 } | Should -Throw '*no visible window*No accounts were stopped*'
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 2 -Exactly
        Should -Invoke -ModuleName tandem-chatgpt-desktop Stop-Process -Times 0
    }
    It 'opens only missing accounts: <Scenario>' -ForEach @(
        @{ Scenario = 'neither open'; MainOpen = $false; ProfileOpen = $false; Starts = 2 }
        @{ Scenario = 'main open'; MainOpen = $true; ProfileOpen = $false; Starts = 1 }
        @{ Scenario = 'profile open'; MainOpen = $false; ProfileOpen = $true; Starts = 1 }
        @{ Scenario = 'both open'; MainOpen = $true; ProfileOpen = $true; Starts = 0 }
    ) {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTMainProcess {
            if ($MainOpen) { [pscustomobject]@{ CommandLine = 'ChatGPT.exe'; ProcessId = 10 } }
            if ($ProfileOpen) { [pscustomobject]@{ CommandLine = ('ChatGPT.exe --user-data-dir="' + (Join-Path $allRoot 'account2\electron') + '"'); ProcessId = 20 } }
        }
        $result = @(Start-ChatGPTAllAccounts -Root $allRoot)
        $result.Count | Should -Be 2
        @($result | Where-Object Status -EQ AlreadyRunning).Count | Should -Be (2 - $Starts)
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times $Starts -Exactly
        if ($MainOpen) { Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 0 -ParameterFilter { $Name -eq 'main' } }
        if ($ProfileOpen) { Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 0 -ParameterFilter { $Name -eq 'account2' } }
    }
    It 'recognizes an explicitly selected native data folder without relaunching it' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTMainProcess { [pscustomobject]@{ CommandLine = ('ChatGPT.exe --user-data-dir="' + (Join-Path $env:APPDATA 'ChatGPT') + '"'); ProcessId = 10 } }
        $null = Start-ChatGPTAllAccounts -Root $allRoot
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 1 -Exactly -ParameterFilter { $Name -eq 'account2' -and $Root -eq $allRoot }
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 0 -ParameterFilter { $Name -eq 'main' }
    }
    It 'does not mistake an unmanaged profile for the primary account' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTMainProcess { [pscustomobject]@{ CommandLine = 'ChatGPT.exe --user-data-dir="C:\unmanaged\electron"'; ProcessId = 30 } }
        $null = Start-ChatGPTAllAccounts -Root $allRoot
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 2 -Exactly
    }
    It 'tries the other accounts if one fails and reports the error' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTMainProcess { }
        Mock -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile { if ($Name -eq 'main') { throw 'synthetic launch failure' } }
        { Start-ChatGPTAllAccounts -Root $allRoot } | Should -Throw '*main: synthetic launch failure*'
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 1 -Exactly -ParameterFilter { $Name -eq 'account2' }
    }
    It 'supports WhatIf without launching any accounts' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTMainProcess { }
        Start-ChatGPTAllAccounts -Root $allRoot -WhatIf
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 0
    }
    It 'rejects a conflicting managed main profile before launching anything' {
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTProfile { [pscustomobject]@{ Name = 'main' } }
        { Start-ChatGPTAllAccounts -Root $allRoot } | Should -Throw '*conflicts*'
        Should -Invoke -ModuleName tandem-chatgpt-desktop Start-ChatGPTProfile -Times 0
    }
}

Describe 'All Accounts shortcuts' {
    BeforeEach {
        Mock -ModuleName tandem-chatgpt-desktop Get-LauncherIcon { 'C:\local\persistent.ico' }
        $shortcutRoot = Join-Path $TestDrive ('shortcuts root-' + [guid]::NewGuid())
        $shortcutFolder = Join-Path $TestDrive ('desktop-' + [guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $shortcutFolder -Force
        Mock -ModuleName tandem-chatgpt-desktop Get-ShortcutFolder { $shortcutFolder }
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage { [pscustomobject]@{ Exe = 'C:\Vendor\ChatGPT.exe' } }
    }
    It 'creates a launch-all shortcut and removes only its own links' {
        $paths = @(New-ChatGPTAllAccountsShortcut -Root $shortcutRoot)
        $paths.Count | Should -Be 1
        $shell = New-Object -ComObject WScript.Shell
        try {
            $link = $shell.CreateShortcut($paths[0])
            $link.Arguments | Should -BeLike '*launch-all -Root*shortcuts root* -Gui'
            $link.Arguments | Should -Not -BeLike '* switch *'
            $link.WindowStyle | Should -Be 7
        } finally { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        & (Get-Module tandem-chatgpt-desktop) { param($R) Remove-AllAccountsShortcut -Root $R } $shortcutRoot
        $paths[0] | Should -Not -Exist
    }
    It 'does not remove a link subsequently assigned to another profile root' {
        $path = @(New-ChatGPTAllAccountsShortcut -Root $shortcutRoot)[0]
        $shell = New-Object -ComObject WScript.Shell
        try {
            $link = $shell.CreateShortcut($path)
            $link.Arguments = 'launch-all -Root "C:\another-root"'
            $link.Save()
        } finally { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        & (Get-Module tandem-chatgpt-desktop) { param($R) Remove-AllAccountsShortcut -Root $R } $shortcutRoot
        $path | Should -Exist
    }
    It 'does not create any shortcut or root with WhatIf' {
        New-ChatGPTAllAccountsShortcut -Root $shortcutRoot -WhatIf
        $shortcutRoot | Should -Not -Exist
        @(Get-ChildItem -LiteralPath $shortcutFolder).Count | Should -Be 0
    }
}


Describe 'Update safe launcher icons' {
    BeforeEach {
        $iconRoot = Join-Path $TestDrive ('icon-root-' + [guid]::NewGuid())
        $vendorRoot = Join-Path $TestDrive ('vendor-version-' + [guid]::NewGuid())
        $linkFolder = Join-Path $TestDrive ('links-' + [guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $vendorRoot, $linkFolder
        Set-Content (Join-Path $vendorRoot 'ChatGPT.exe') 'synthetic package'
        Mock -ModuleName tandem-chatgpt-desktop Get-ShortcutFolder { $linkFolder }
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage { [pscustomobject]@{ Exe = (Join-Path $vendorRoot 'ChatGPT.exe') } }
        Mock -ModuleName tandem-chatgpt-desktop Save-ProfileIcon {
            $path = Join-Path $Layout.Dir 'icon-test.ico'
            [IO.File]::WriteAllBytes($path, [byte[]]@(0, 0, 1, 0))
            $path
        }
    }
    It 'keeps Main and All Accounts icons valid after the vendor package is removed' {
        $null = New-ChatGPTAllAccountsShortcut -Root $iconRoot
        & (Get-Module tandem-chatgpt-desktop) { param($R) Save-MainTaskbarShortcut -Root $R -App (Get-ChatGPTPackage) } $iconRoot
        Remove-Item -LiteralPath (Join-Path $vendorRoot 'ChatGPT.exe') -Force
        $shell = New-Object -ComObject WScript.Shell
        try {
            foreach ($name in @('ChatGPT (Main).lnk', 'ChatGPT (All Accounts).lnk')) {
                $link = $shell.CreateShortcut((Join-Path $linkFolder $name))
                $icon = $link.IconLocation -replace ',0$', ''
                $icon | Should -BeLike ($iconRoot + '\*')
                $icon | Should -Exist
            }
        } finally { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    It 'does not mistake a background process for a visible native window' {
        InModuleScope tandem-chatgpt-desktop {
            Test-DesktopWindow -Process @() | Should -BeFalse
            Test-DesktopWindow -Process @([pscustomobject]@{ ProcessId = $PID }) | Should -BeFalse
        }
    }
}


Describe 'Shell refresh and real window lifecycle' {
    It 'notifies Windows when Main and All Accounts links are rewritten' {
        $root = Join-Path $TestDrive ('refresh-' + [guid]::NewGuid())
        $folder = Join-Path $TestDrive ('links-' + [guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $folder
        Mock -ModuleName tandem-chatgpt-desktop Get-ShortcutFolder { $folder }
        Mock -ModuleName tandem-chatgpt-desktop Get-ChatGPTPackage { [pscustomobject]@{ Exe = 'C:\Vendor\ChatGPT.exe' } }
        Mock -ModuleName tandem-chatgpt-desktop Get-LauncherIcon { 'C:\local\icon.ico' }
        Mock -ModuleName tandem-chatgpt-desktop Update-ShortcutShell { }
        foreach ($repeat in 1..2) {
            $null = New-ChatGPTAllAccountsShortcut -Root $root
            & (Get-Module tandem-chatgpt-desktop) { param($R) Save-MainTaskbarShortcut -Root $R -App (Get-ChatGPTPackage) } $root
        }
        Should -Invoke -ModuleName tandem-chatgpt-desktop Update-ShortcutShell -Times 4 -Exactly
    }
    It 'detects an actual window becoming visible, hidden and tool-only' {
        if (-not ('TandemWindowFixture' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowFixture.cs') }
        InModuleScope tandem-chatgpt-desktop {
            $window = [TandemWindowFixture]::Create($false)
            $tool = [TandemWindowFixture]::Create($true)
            $owner = @([pscustomobject]@{ ProcessId = $PID })
            try {
                Test-DesktopWindow -Process $owner | Should -BeFalse
                [TandemWindowFixture]::Show($window)
                Test-DesktopWindow -Process $owner | Should -BeTrue
                [TandemWindowFixture]::Hide($window)
                Test-DesktopWindow -Process $owner | Should -BeFalse
                [TandemWindowFixture]::Show($tool)
                Test-DesktopWindow -Process $owner | Should -BeFalse
            } finally {
                $null = [TandemWindowFixture]::DestroyWindow($window)
                $null = [TandemWindowFixture]::DestroyWindow($tool)
            }
        }
    }
    It 'delivers a native shell update without changing shortcut arguments' {
        InModuleScope tandem-chatgpt-desktop -Parameters @{ R = $TestDrive } {
            param($R)
            $path = Join-Path $R 'shell-refresh.lnk'
            $shell = New-Object -ComObject WScript.Shell
            try {
                $link = $shell.CreateShortcut($path)
                $link.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
                $link.Arguments = 'synthetic.txt'
                $link.Save()
                { Update-ShortcutShell -Path $path } | Should -Not -Throw
                $shell.CreateShortcut($path).Arguments | Should -Be 'synthetic.txt'
            } finally { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        }
    }
}


Describe 'Taskbar helper icon lifetime' {
    It 'repairs inherited properties after the icon-owning helper exits: <OldId>' -ForEach @(
        @{ OldId = 'Tandem.Lifetime.Test'; NewId = 'Tandem.Lifetime.Test' }
        @{ OldId = 'Tandem.ChatGPT.old.main'; NewId = 'Tandem.ChatGPT.v2.main' }
    ) {
        if (-not ('TandemWindowFixture' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowFixture.cs') }
        $library = Join-Path $PSScriptRoot '..\taskbar-identity.cs'
        InModuleScope tandem-chatgpt-desktop -Parameters @{ R = $TestDrive; Library = $library; Old = $OldId; Current = $NewId } {
            param($R, $Library, $Old, $Current)
            Initialize-TaskbarApi
            Add-Type -AssemblyName System.Windows.Forms
            $window = [TandemWindowFixture]::Create($false)
            $icon = Join-Path $R 'lifetime.ico'
            $stream = [IO.File]::Create($icon)
            try { [Drawing.SystemIcons]::Information.Save($stream) } finally { $stream.Dispose() }
            $script = Join-Path $R 'transient-helper.ps1'
            @'
param([long]$Window, [string]$Library, [string]$Icon, [string]$Identity)
Add-Type -Path $Library
[Tandem.ChatGPT.TaskbarIdentity]::Apply([intptr]$Window, $Identity, 'synthetic.exe', 'Synthetic', $Icon)
# Deliberately exit without RestoreAll, as if the resident helper had crashed.
'@ | Set-Content -LiteralPath $script -Encoding UTF8
            $helper = $null
            try {
                $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $helper = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Window {1} -Library "{2}" -Icon "{3}" -Identity "{4}"' -f $script, [long]$window, $Library, $icon, $Old)
                $limit = (Get-Date).AddSeconds(25)
                while (-not $helper.WaitForExit(20)) {
                    [Windows.Forms.Application]::DoEvents()
                    if ((Get-Date) -gt $limit) { throw 'Synthetic helper timed out' }
                }
                $helper.ExitCode | Should -Be 0
                [Tandem.ChatGPT.TaskbarIdentity]::ReadWindow($window, 5) | Should -Be $Old
                [Tandem.ChatGPT.TaskbarIdentity]::WindowIconsValid($window) | Should -BeFalse
                [Tandem.ChatGPT.TaskbarIdentity]::NeedsApply($window, $Current, $icon) | Should -BeTrue
                [Tandem.ChatGPT.TaskbarIdentity]::Apply($window, $Current, 'synthetic.exe', 'Synthetic', $icon)
                [Tandem.ChatGPT.TaskbarIdentity]::WindowIconsValid($window) | Should -BeTrue
                [Tandem.ChatGPT.TaskbarIdentity]::NeedsApply($window, $Current, $icon) | Should -BeFalse
                [Tandem.ChatGPT.TaskbarIdentity]::RestoreAll()
                [Tandem.ChatGPT.TaskbarIdentity]::ReadWindow($window, 5) | Should -BeNullOrEmpty
            } finally {
                if ($null -ne $helper -and -not $helper.HasExited) { $helper.Kill() }
                [Tandem.ChatGPT.TaskbarIdentity]::RestoreAll()
                $null = [TandemWindowFixture]::DestroyWindow($window)
            }
        }
    }
    It 'rejects an invalid icon file before changing taskbar metadata' {
        if (-not ('TandemWindowFixture' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowFixture.cs') }
        InModuleScope tandem-chatgpt-desktop {
            Initialize-TaskbarApi
            $window = [TandemWindowFixture]::Create($false)
            try {
                { [Tandem.ChatGPT.TaskbarIdentity]::Apply($window, 'Synthetic.Invalid', 'synthetic.exe', 'Synthetic', 'no-such-icon.ico') } | Should -Throw '*Could not load taskbar icons*'
                [Tandem.ChatGPT.TaskbarIdentity]::ReadWindow($window, 5) | Should -BeNullOrEmpty
            } finally { $null = [TandemWindowFixture]::DestroyWindow($window) }
        }
    }
}
