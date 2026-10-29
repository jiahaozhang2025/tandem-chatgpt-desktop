# Validation

## October 29, 2026

* 76 Pester tests passed on Windows PowerShell 5.1 and PowerShell 7. PSScriptAnalyzer found no warnings or errors in the production scripts.
* All Accounts coverage includes neither/either/both accounts running, custom roots with spaces, unmanaged profiles, partial launch failure, WhatIf, shortcut creation, and safe uninstall ownership checks. These tests mock app launches.
* Installed Desktop and Start menu All Accounts shortcuts. A live `launch-all` call skipped both running accounts and preserved their process IDs. Upgrading preserved the taskbar configuration byte for byte.
* Closed-account launch combinations were tested with mocks rather than interrupting live work. This command does not transfer conversation history.

## October 26, 2026

Taskbar options were checked locally with the Microsoft Store ChatGPT package `OpenAI.Codex` version 26.1021.3705.0.

* Pester 5.9.1: 64 tests passed on Windows PowerShell 5.1 and PowerShell 7. Coverage includes profile launch/isolation checks, retained settings, icons, removal, installation from a marked download, mode persistence, the Disable alias, invalid modes and WhatIf, native shell-property restoration on an invisible test window, and shortcut identity preservation.
* PSScriptAnalyzer: no warnings or errors.
* Separate mode was applied to two existing account windows with different taskbar identities, labels and colored icon resources. The app processes were not restarted.
* A live `separate -> grouped -> separate` round trip removed and restored the per-account window identities. Separate mode was left enabled.
* The installer accepted `-TaskbarMode Separate`. Reinstalling with that option omitted preserved the preference file byte for byte.

Tests use temporary profiles/shortcuts and mock app/process launches. Mode changes operate on Windows shell properties and shortcut metadata; they do not merge accounts or conversation histories. Existing taskbar pins are managed by Windows and may need to be refreshed after changing modes.
