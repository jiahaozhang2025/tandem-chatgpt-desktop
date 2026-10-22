<#
.SYNOPSIS
  Installs chatgpt-profile for the current user (no admin rights needed).

.DESCRIPTION
  Copies the scripts to %LOCALAPPDATA%\Programs\tandem-chatgpt-desktop (or -Destination)
  so profile shortcuts keep working after this folder is moved or deleted. Running it
  again upgrades in place; existing profiles and shortcuts are kept.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Destination = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\tandem-chatgpt-desktop')
)

$ErrorActionPreference = 'Stop'

$source = $PSScriptRoot
$destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ($destinationPath -eq [IO.Path]::GetFullPath($source).TrimEnd('\')) {
    throw 'Run install.ps1 from the downloaded repository, not from the install folder.'
}

if ($PSCmdlet.ShouldProcess($destinationPath, 'Install chatgpt-profile')) {
    $moduleTarget = Join-Path -Path $destinationPath -ChildPath 'tandem-chatgpt-desktop'
    $null = New-Item -ItemType Directory -Force -Path $moduleTarget
    foreach ($file in 'chatgpt-profile.ps1', 'uninstall.ps1', 'README.md', 'LICENSE') {
        Copy-Item -LiteralPath (Join-Path -Path $source -ChildPath $file) -Destination $destinationPath -Force
    }
    foreach ($file in 'tandem-chatgpt-desktop.psd1', 'tandem-chatgpt-desktop.psm1') {
        Copy-Item -LiteralPath (Join-Path -Path $source -ChildPath "tandem-chatgpt-desktop\$file") -Destination $moduleTarget -Force
    }
    # Lets cmd.exe and the Run dialog call the tool without typing powershell.exe.
    Set-Content -LiteralPath (Join-Path -Path $destinationPath -ChildPath 'chatgpt-profile.cmd') -Encoding Ascii -Value @(
        '@echo off'
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0chatgpt-profile.ps1" %*'
    )
    # Copies keep the "downloaded from the internet" mark of a downloaded zip, which makes
    # Import-Module fail under a RemoteSigned execution policy.
    Get-ChildItem -LiteralPath $destinationPath -Recurse -File | Unblock-File

    $cli = Join-Path -Path $destinationPath -ChildPath 'chatgpt-profile.cmd'
    Write-Output "Installed to $destinationPath"
    Write-Output ''
    Write-Output 'Create a profile for your second account (adds Start menu and desktop shortcuts):'
    Write-Output "  `"$cli`" new account2 -Label `"Account 2`""
    Write-Output 'Then open the new shortcut and sign in. Check your setup any time with:'
    Write-Output "  `"$cli`" doctor -Deep"
}
