<#
.SYNOPSIS
  chatgpt-profile: run several ChatGPT desktop accounts side by side on Windows.

.DESCRIPTION
  chatgpt-profile new <name> [-Label <text>] [-Color <color>] [-Badge <1-2 chars>]
                             [-StartMenuShortcut] [-NoDesktopShortcut]
  chatgpt-profile launch <name>
  chatgpt-profile list
  chatgpt-profile stop <name>
  chatgpt-profile remove <name> [-KeepData] [-Force]
  chatgpt-profile doctor [-Deep]

  Every command accepts -Root <folder> (default: %USERPROFILE%\ChatGPTProfiles).
  Colors: Orange, Blue, Green, Purple, Red, Teal, Pink, Gray.

.EXAMPLE
  chatgpt-profile new work -Label Work -Color Blue
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('new', 'launch', 'list', 'stop', 'remove', 'doctor', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)][string]$Name,
    [string]$Label,
    [string]$Color,
    [string]$Badge,
    [string]$Root,
    [switch]$NoDesktopShortcut,
    [switch]$StartMenuShortcut,
    [switch]$KeepData,
    [switch]$Force,
    [switch]$Deep,
    # Used by shortcuts: report errors in a message box because there is no console.
    [switch]$Gui
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    Get-Help -Name $PSCommandPath -Detailed | Out-String | Write-Output
}

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'ChatGPTSideBySide\ChatGPTSideBySide.psd1') -Force
    $common = @{}
    if ($Root) { $common.Root = $Root }
    if ($Command -in 'new', 'launch', 'stop', 'remove' -and -not $Name) {
        throw "'$Command' needs a profile name, for example: chatgpt-profile $Command work"
    }

    switch ($Command) {
        'new' {
            $options = @{ Name = $Name }
            if ($Label) { $options.Label = $Label }
            if ($Color) { $options.Color = $Color }
            if ($Badge) { $options.Badge = $Badge }
            $result = New-ChatGPTProfile @options @common -NoDesktopShortcut:$NoDesktopShortcut -StartMenuShortcut:$StartMenuShortcut
            $result | Format-List | Out-String | Write-Output
            if (-not $result.SignedIn) {
                Write-Output "Next: open the 'ChatGPT ($($result.Label))' shortcut (or run 'chatgpt-profile launch $Name') and sign in."
            }
        }
        'launch' { $null = Start-ChatGPTProfile -Name $Name @common }
        'list' { Get-ChatGPTProfile @common | Format-Table -AutoSize | Out-String | Write-Output }
        'stop' { Stop-ChatGPTProfile -Name $Name @common }
        'remove' {
            if ($Force) { Remove-ChatGPTProfile -Name $Name -KeepData:$KeepData -Confirm:$false @common }
            else { Remove-ChatGPTProfile -Name $Name -KeepData:$KeepData @common }
        }
        'doctor' { Test-ChatGPTSideBySide -Deep:$Deep @common | Format-Table -AutoSize -Wrap | Out-String | Write-Output }
        default { Show-Usage }
    }
} catch {
    $message = $_.Exception.Message
    if ($Gui) {
        Add-Type -AssemblyName System.Windows.Forms
        $title = 'ChatGPT side by side'
        if ($Name) { $title = "ChatGPT ($Name)" }
        $null = [System.Windows.Forms.MessageBox]::Show($message, $title, 'OK', 'Error')
    } else {
        Write-Error -Message $message -ErrorAction Continue
    }
    exit 1
}
