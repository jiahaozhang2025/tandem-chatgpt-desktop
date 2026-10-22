@{
    RootModule           = 'tandem-chatgpt-desktop.psm1'
    ModuleVersion        = '0.1.2'
    GUID                 = '6f1d2b7e-3c4a-4e8b-9a51-2d7c8e0f4b13'
    Author               = 'Jiahao Zhang'
    Copyright            = '(c) 2026 Jiahao Zhang. MIT License.'
    Description          = 'Run the ChatGPT desktop app for Windows as several isolated instances, one per account, side by side. Unofficial; not affiliated with OpenAI.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'New-ChatGPTProfile'
        'Start-ChatGPTProfile'
        'Stop-ChatGPTProfile'
        'Get-ChatGPTProfile'
        'Remove-ChatGPTProfile'
        'Test-ChatGPTProfileSupport'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('ChatGPT', 'Codex', 'Windows', 'MultiAccount', 'Profiles')
            LicenseUri = 'https://github.com/jiahaozhang2025/tandem-chatgpt-desktop/blob/main/LICENSE'
            ProjectUri = 'https://github.com/jiahaozhang2025/tandem-chatgpt-desktop'
        }
    }
}
