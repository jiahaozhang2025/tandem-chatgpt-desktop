# Changelog

## 0.1.0 - 2026-10-16

First release.

- `chatgpt-profile` commands: `new`, `launch`, `list`, `stop`, `remove`, `doctor`.
- Launches ChatGPT inside its Store package with a per-profile `CODEX_HOME` and window data folder, using `Invoke-CommandInDesktopPackage -PreventBreakaway` and a `cmd.exe` wrapper.
- Safety check: closes a new instance that doesn't start using its own `CODEX_HOME`, so it can't share another account's login.
- Desktop and Start menu shortcuts with a colored, lettered badge per profile.
- Per-user installer and uninstaller.
