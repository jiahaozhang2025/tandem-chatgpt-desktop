#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Unit tests. Nothing here starts ChatGPT or touches real profiles, shortcuts or the
# Store package: package lookups, process lookups and the in-package launch are mocked.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ChatGPTSideBySide\ChatGPTSideBySide.psd1') -Force
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

    function New-FakePackage {
        $drive = (Get-PSDrive TestDrive).Root
        [pscustomobject]@{
            Version    = '26.1.0.0'
            FamilyName = 'OpenAI.Codex_test'
            Exe        = 'C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe'
            BaseIcon   = Join-Path $drive 'base.ico'
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
        InModuleScope ChatGPTSideBySide -Parameters @{ N = $_ } {
            param($N)
            { Assert-ProfileName -Name $N } | Should -Not -Throw
        }
    }

    It 'rejects the name <_>' -ForEach @('', '-x', '_x', 'a b', '..', 'a\b', 'a/b', 'a.b', ('a' * 65)) {
        InModuleScope ChatGPTSideBySide -Parameters @{ N = $_ } {
            param($N)
            { Assert-ProfileName -Name $N } | Should -Throw '*Invalid profile name*'
        }
    }

    It 'rejects a root with non-ASCII characters' {
        InModuleScope ChatGPTSideBySide {
            { Resolve-ProfileRoot -Root ('C:\Users\Jos' + [char]0xE9 + '\ChatGPTProfiles') } | Should -Throw '*non-ASCII*'
        }
    }

    It 'rejects a root containing %' {
        InModuleScope ChatGPTSideBySide { { Resolve-ProfileRoot -Root 'C:\100%\profiles' } | Should -Throw "*'%'*" }
    }

    It 'rejects a drive root' {
        InModuleScope ChatGPTSideBySide { { Resolve-ProfileRoot -Root 'C:\' } | Should -Throw '*drive root*' }
    }

    It 'trims a trailing backslash' {
        InModuleScope ChatGPTSideBySide { Resolve-ProfileRoot -Root 'C:\Profiles\' | Should -Be 'C:\Profiles' }
    }
}

Describe 'Get-ProfileLayout' {
    It 'keeps everything under <root>\<name>' {
        InModuleScope ChatGPTSideBySide {
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
        InModuleScope ChatGPTSideBySide {
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
        InModuleScope ChatGPTSideBySide -Parameters @{ Procs = $procs } {
            param($Procs)
            $layout = Get-ProfileLayout -Name 'account2' -Root 'C:\P'
            @(Get-ProfileProcess -Layout $layout -Process $Procs).ProcessId | Should -Be @(1)
        }
    }

    It 'ignores differences in letter case' {
        $procs = @([pscustomobject]@{ ProcessId = 9; CommandLine = '"ChatGPT.exe" --user-data-dir="c:\p\WORK\electron"' })
        InModuleScope ChatGPTSideBySide -Parameters @{ Procs = $procs } {
            param($Procs)
            $layout = Get-ProfileLayout -Name 'work' -Root 'C:\P'
            @(Get-ProfileProcess -Layout $layout -Process $Procs).Count | Should -Be 1
        }
    }

    It 'skips Electron helper processes' {
        Mock -ModuleName ChatGPTSideBySide Get-CimInstance {
            [pscustomobject]@{ ProcessId = 1; CommandLine = '"ChatGPT.exe" --user-data-dir="C:\P\w\electron"' }
            [pscustomobject]@{ ProcessId = 2; CommandLine = '"ChatGPT.exe" --type=renderer --user-data-dir="C:\P\w\electron"' }
            [pscustomobject]@{ ProcessId = 3; CommandLine = $null }
        }
        InModuleScope ChatGPTSideBySide { @(Get-ChatGPTMainProcess).ProcessId | Should -Be @(1) }
    }
}

Describe 'Start-ChatGPTProfile' {
    BeforeEach {
        $root = Join-Path $TestDrive 'profiles'
        $null = New-TestProfileFolder -Root $root -Name 'work'
        Mock -ModuleName ChatGPTSideBySide Get-ChatGPTPackage { New-FakePackage }
        Mock -ModuleName ChatGPTSideBySide Get-ProfileProcess { }
        Mock -ModuleName ChatGPTSideBySide Close-ProfileProcess { 1 }
    }

    It 'throws for a profile that does not exist' {
        { Start-ChatGPTProfile -Name 'nope' -Root $root } | Should -Throw '*does not exist*'
    }

    It 'launches inside the package and confirms the profile CODEX_HOME is used' {
        Mock -ModuleName ChatGPTSideBySide Invoke-InPackage {
            Set-Content -LiteralPath (Join-Path (Split-Path $ScriptPath) 'codex-home\state_5.sqlite') -Value 'x'
        }
        $result = Start-ChatGPTProfile -Name 'work' -Root $root -VerifySeconds 10

        $result.Status | Should -Be 'Started'
        Should -Invoke -ModuleName ChatGPTSideBySide Invoke-InPackage -Times 1 -Exactly -ParameterFilter {
            $FamilyName -eq 'OpenAI.Codex_test' -and $ScriptPath -like '*\profiles\work\launch.cmd'
        }
        Should -Invoke -ModuleName ChatGPTSideBySide Close-ProfileProcess -Times 0
        $cmd = Get-Content -LiteralPath (Join-Path $root 'work\launch.cmd')
        $cmd[1] | Should -Be ('set "CODEX_HOME=' + (Join-Path $root 'work\codex-home') + '"')
        $cmd[3] | Should -BeLike 'start "" "C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe" --user-data-dir=*'
        Get-Content -LiteralPath (Join-Path $root 'work\codex-home\config.toml') | Should -Be 'cli_auth_credentials_store = "file"'
        Get-Content -LiteralPath (Join-Path $root 'work\launcher.log') -Raw | Should -BeLike '*verified*'
    }

    It 'closes the instance and throws when the profile CODEX_HOME stays untouched' {
        Mock -ModuleName ChatGPTSideBySide Invoke-InPackage { }
        { Start-ChatGPTProfile -Name 'work' -Root $root -VerifySeconds 1 } | Should -Throw '*did not start using*'
        Should -Invoke -ModuleName ChatGPTSideBySide Close-ProfileProcess -Times 1 -Exactly
        Get-Content -LiteralPath (Join-Path $root 'work\launcher.log') -Raw | Should -BeLike '*ERROR*'
    }

    It 'only brings the window forward when the profile is already running' {
        Mock -ModuleName ChatGPTSideBySide Get-ProfileProcess { [pscustomobject]@{ ProcessId = 42; CommandLine = 'x' } }
        Mock -ModuleName ChatGPTSideBySide Invoke-InPackage { }
        Mock -ModuleName ChatGPTSideBySide Test-FreshWrite { $false }

        (Start-ChatGPTProfile -Name 'work' -Root $root).Status | Should -Be 'AlreadyRunning'
        Should -Invoke -ModuleName ChatGPTSideBySide Invoke-InPackage -Times 1 -Exactly
        Should -Invoke -ModuleName ChatGPTSideBySide Test-FreshWrite -Times 0
    }
}

Describe 'New-ChatGPTProfile' {
    BeforeAll {
        $png = New-TestPng 256
        InModuleScope ChatGPTSideBySide -Parameters @{ Png = $png } {
            param($Png)
            Write-IcoFile -Path (Join-Path (Get-PSDrive TestDrive).Root 'base.ico') -Frame @([pscustomobject]@{ Size = 256; Bytes = $Png })
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive 'profiles'
        $shortcuts = Join-Path $TestDrive 'shortcuts'
        $null = New-Item -ItemType Directory -Force -Path $shortcuts
        Mock -ModuleName ChatGPTSideBySide Get-ChatGPTPackage { New-FakePackage }
        Mock -ModuleName ChatGPTSideBySide Get-ShortcutFolder { Join-Path (Get-PSDrive TestDrive).Root 'shortcuts' }
        Mock -ModuleName ChatGPTSideBySide Get-ChatGPTMainProcess { }
    }

    AfterEach {
        Remove-Item -LiteralPath $root, $shortcuts -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates the folders, login config, metadata, icon and shortcut' {
        $result = New-ChatGPTProfile -Name 'work' -Label 'Work' -Color 'Blue' -Root $root -Confirm:$false

        $result.Name | Should -Be 'work'
        $result.Label | Should -Be 'Work'
        $result.SignedIn | Should -BeFalse
        Join-Path $root 'work\electron' | Should -Exist
        Get-Content -LiteralPath (Join-Path $root 'work\codex-home\config.toml') | Should -Be 'cli_auth_credentials_store = "file"'

        $meta = Get-Content -LiteralPath (Join-Path $root 'work\profile.json') -Raw | ConvertFrom-Json
        $meta.label | Should -Be 'Work'
        $meta.color | Should -Be 'Blue'
        $meta.badge | Should -Be 'W'

        $icon = [IO.File]::ReadAllBytes((Join-Path $root 'work\icon.ico'))
        $icon[0..3] | Should -Be @(0, 0, 1, 0)
        [BitConverter]::ToUInt16($icon, 4) | Should -Be 4

        $lnkPath = Join-Path $shortcuts 'ChatGPT (Work).lnk'
        $lnkPath | Should -Exist
        @($meta.shortcuts) | Should -Be @($lnkPath)
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
        $link.TargetPath | Should -BeLike '*\WindowsPowerShell\v1.0\powershell.exe'
        $link.Arguments | Should -BeLike ('*chatgpt-profile.ps1" launch work -Root "' + $root + '" -Gui')
        $link.IconLocation | Should -BeLike '*\work\icon.ico,0'
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
    }

    It 'derives the badge <Badge> from the label <Label>' -ForEach @(
        @{ Label = 'Account 2'; Badge = '2' }
        @{ Label = 'Team 12'; Badge = '12' }
        @{ Label = 'work'; Badge = 'W' }
        @{ Label = '!!'; Badge = '?' }
    ) {
        InModuleScope ChatGPTSideBySide -Parameters @{ L = $Label } { param($L) Get-DefaultBadge -Label $L } | Should -Be $Badge
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
        Mock -ModuleName ChatGPTSideBySide Get-ChatGPTMainProcess {
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
        Mock -ModuleName ChatGPTSideBySide Close-ProfileProcess { 0 }
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
        Should -Invoke -ModuleName ChatGPTSideBySide Close-ProfileProcess -Times 1 -Exactly
    }

    It 'keeps the data with -KeepData' {
        Remove-ChatGPTProfile -Name 'work' -Root $root -KeepData -Confirm:$false
        $dir | Should -Exist
        $lnk | Should -Not -Exist
        Should -Invoke -ModuleName ChatGPTSideBySide Close-ProfileProcess -Times 0
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
        Mock -ModuleName ChatGPTSideBySide Get-ProfileProcess { }
        InModuleScope ChatGPTSideBySide {
            Close-ProfileProcess -Layout (Get-ProfileLayout -Name 'w' -Root 'C:\P') | Should -Be 0
        }
    }

    It 'ends the instance and its whole process tree' {
        Mock -ModuleName ChatGPTSideBySide Get-ProfileProcess { [pscustomobject]@{ ProcessId = 101; CommandLine = 'x' } }
        Mock -ModuleName ChatGPTSideBySide Get-ProcessTreeId { 103, 102, 101 }
        Mock -ModuleName ChatGPTSideBySide Stop-Process { }
        InModuleScope ChatGPTSideBySide {
            Close-ProfileProcess -Layout (Get-ProfileLayout -Name 'w' -Root 'C:\P') | Should -Be 1
        }
        Should -Invoke -ModuleName ChatGPTSideBySide Stop-Process -Times 3 -Exactly
        Should -Invoke -ModuleName ChatGPTSideBySide Get-ProcessTreeId -Times 1 -Exactly -ParameterFilter { $RootId -contains 101 }
    }
}

Describe 'Icons' {
    It 'round-trips PNG frames and picks the largest one' {
        $small = New-TestPng 16
        $large = New-TestPng 256
        InModuleScope ChatGPTSideBySide -Parameters @{ Small = $small; Large = $large } {
            param($Small, $Large)
            $path = Join-Path (Get-PSDrive TestDrive).Root 'frames.ico'
            Write-IcoFile -Path $path -Frame @(
                [pscustomobject]@{ Size = 16; Bytes = $Small }
                [pscustomobject]@{ Size = 256; Bytes = $Large }
            )
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
        InModuleScope ChatGPTSideBySide -Parameters @{ P = $path } {
            param($P)
            $found = Test-FileContainsText -Path $P -Text 'CODEX_HOME', 'CODEX_ELECTRON_USER_DATA_PATH' -ChunkSize 16
            $found['CODEX_HOME'] | Should -BeTrue
            $found['CODEX_ELECTRON_USER_DATA_PATH'] | Should -BeTrue
        }
    }

    It 'reports text that is missing' {
        $path = Join-Path $TestDrive 'bundle2.bin'
        Set-Content -LiteralPath $path -NoNewline -Encoding Ascii -Value 'only CODEX_HOME here'
        InModuleScope ChatGPTSideBySide -Parameters @{ P = $path } {
            param($P)
            $found = Test-FileContainsText -Path $P -Text 'CODEX_HOME', 'CODEX_ELECTRON_USER_DATA_PATH' -ChunkSize 16
            $found['CODEX_HOME'] | Should -BeTrue
            $found['CODEX_ELECTRON_USER_DATA_PATH'] | Should -BeFalse
        }
    }
}

Describe 'Test-ChatGPTSideBySide' {
    BeforeEach {
        Mock -ModuleName ChatGPTSideBySide Get-ChatGPTPackage { New-FakePackage }
    }

    It 'confirms app support with -Deep when the bundle reads both variables' {
        Set-Content -LiteralPath (Join-Path $TestDrive 'app.asar') -Encoding Ascii -Value 'a CODEX_HOME b CODEX_ELECTRON_USER_DATA_PATH c'
        $check = Test-ChatGPTSideBySide -Deep -Root (Join-Path $TestDrive 'profiles') | Where-Object Check -EQ 'App support'
        $check.Status | Should -Be 'OK'
    }

    It 'fails app support when the bundle no longer mentions a variable' {
        Set-Content -LiteralPath (Join-Path $TestDrive 'app.asar') -Encoding Ascii -Value 'a CODEX_HOME b'
        $check = Test-ChatGPTSideBySide -Deep -Root (Join-Path $TestDrive 'profiles') | Where-Object Check -EQ 'App support'
        $check.Status | Should -Be 'FAIL'
        $check.Detail | Should -BeLike '*CODEX_ELECTRON_USER_DATA_PATH*'
    }

    It 'reports a missing app instead of throwing' {
        Mock -ModuleName ChatGPTSideBySide Get-ChatGPTPackage { throw 'not installed' }
        $results = Test-ChatGPTSideBySide -Root (Join-Path $TestDrive 'profiles')
        ($results | Where-Object Check -EQ 'ChatGPT app').Status | Should -Be 'FAIL'
        ($results | Where-Object Check -EQ 'App support').Status | Should -Be 'SKIP'
    }
}
