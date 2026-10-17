<#
.SYNOPSIS
  Uninstalls chatgpt-profile for the current user.

.DESCRIPTION
  Removes every profile's shortcuts (they would point at deleted scripts) and the
  installed scripts. Profile folders, including their logins, are kept unless you add
  -RemoveProfiles. Your main ChatGPT app and its login are never touched.
  -Force skips the confirmation prompt (-Confirm:$false does not survive powershell -File).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\tandem-chatgpt-desktop\uninstall.ps1"
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Destination = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\tandem-chatgpt-desktop'),
    [string]$Root,
    [switch]$RemoveProfiles,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if ($Force) { $ConfirmPreference = 'None' }

$destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
$manifest = Join-Path -Path $destinationPath -ChildPath 'tandem-chatgpt-desktop\tandem-chatgpt-desktop.psd1'
if (-not (Test-Path -LiteralPath $manifest)) { throw "chatgpt-profile is not installed in $destinationPath." }

Import-Module -Name $manifest -Force
$common = @{}
if ($Root) { $common.Root = $Root }
$profiles = @(Get-ChatGPTProfile @common)

$action = "Uninstall chatgpt-profile and remove the shortcuts of $($profiles.Count) profile(s), keeping their data"
if ($RemoveProfiles) { $action = "Uninstall chatgpt-profile and delete $($profiles.Count) profile(s) including their logins" }

if ($PSCmdlet.ShouldProcess($destinationPath, $action)) {
    foreach ($p in $profiles) {
        Remove-ChatGPTProfile -Name $p.Name -KeepData:(-not $RemoveProfiles) -Confirm:$false @common
    }
    Remove-Module -Name tandem-chatgpt-desktop -Force
    Remove-Item -LiteralPath $destinationPath -Recurse -Force
    Write-Output "Removed $destinationPath"
    if (-not $RemoveProfiles -and $profiles.Count -gt 0) {
        Write-Output "Profile data was kept in $(Split-Path -Path $profiles[0].Path -Parent)."
    }
}
