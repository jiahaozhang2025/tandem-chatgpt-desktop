# Changelog

## 0.1.2 - 2026-10-21

- Changed: profile icons are now the app's own flat ChatGPT logo in the profile's color, without a badge. The old icon was built from the app's shaded window icon, which looked faded on dark backgrounds such as the Start menu.
- Changed: `new` also adds a Start menu entry. Use `-NoStartMenuShortcut` to skip it, or `-NoDesktopShortcut` to skip the desktop one.
- Changed: icons get a new file name whenever they change, so Windows doesn't keep showing a cached old icon. Running `new` again re-points existing shortcuts to the new icon and deletes the old file.
- Removed: `-Badge` and `-StartMenuShortcut`.

## 0.1.1 - 2026-10-17

- Fixed: installing from a downloaded zip left Windows' "downloaded from the internet" mark on the installed files, so `Import-Module` failed under a RemoteSigned execution policy. The installer now unblocks the files it installs. Shortcuts and `chatgpt-profile.cmd` were not affected.

## 0.1.0 - 2026-10-17

First release.

- `chatgpt-profile` commands: `new`, `launch`, `list`, `stop`, `remove`, `doctor`.
- Launches ChatGPT inside its Store package with a per-profile `CODEX_HOME` and window data folder, using `Invoke-CommandInDesktopPackage -PreventBreakaway` and a `cmd.exe` wrapper.
- Safety check: closes a new instance that doesn't start using its own `CODEX_HOME`, so it can't share another account's login.
- Desktop and Start menu shortcuts with a colored, lettered badge per profile.
- Per-user installer and uninstaller (`-Force` skips the confirmation prompt).
