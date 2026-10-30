# Changelog

## 0.2.2 - 2026-10-29

* Fix All Accounts skipping a hidden background account: check visible taskbar windows, reactivate hidden accounts through their normal launch command, and verify a window appears.
* Use persistent local icons for Main and All Accounts shortcuts instead of versioned Store executable paths. Retain older icon resources for pinned shortcuts and track the current profile icon explicitly.
* Refresh Main shortcuts and restart only the shell helper during installer upgrades, preserving running apps and taskbar preferences. All Accounts also starts a missing taskbar helper.
* Add per-account state/action/process-ID diagnostics in launcher-events.log and tests for hidden accounts and removed package folders.
* Require a visible account window as well as profile writes before reporting startup success. A hidden-window timeout leaves already initialized processes running.

## 0.2.1 — 2026-10-29

* Add `chatgpt-profile launch-all` and Desktop/Start menu **ChatGPT (All Accounts)** shortcuts, installed by default. Open only missing accounts; skip running accounts without activating or restarting them.
* Discover all configured profiles on each use and report launch failures after attempting the other accounts.

## 0.2.0 — 2026-10-26

* Add persistent grouped/separate taskbar options through `chatgpt-profile taskbar grouped` and `chatgpt-profile taskbar separate`.
* Give separate account windows and shortcuts matching taskbar identities and colored icons, including a primary-account shortcut.
* Use a hidden helper to maintain separate identities on new windows. Grouped mode stops the helper and restores the app's normal grouping without restarting ChatGPT.
* Add installer option `-TaskbarMode Grouped|Separate`; upgrades preserve the saved choice when this option is omitted.
* Add native shell-property and configuration tests. Keep each account's login and Codex data in its existing isolated profile.

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
