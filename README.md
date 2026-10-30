# tandem-chatgpt-desktop

Run two (or more) ChatGPT desktop accounts at the same time on Windows, each in its own window with its own login.

**Looking for Claude?** Use the companion [tandem-claude-desktop](https://github.com/jiahaozhang2025/tandem-claude-desktop) launcher, which also includes sign-in routing and experimental Code-history handoff. Each project has its own installer and releases.

The launcher doesn't modify the app, inject code into it, open a debugging port or proxy your requests. Optional separate taskbar icons use a hidden helper while the app is running.

> **Unofficial.** Not affiliated with or endorsed by OpenAI. ChatGPT is a trademark of OpenAI.
> This is for people with more than one ChatGPT account of their own, such as personal and work.
> It is not for sharing accounts or getting around usage limits.

## Requirements

- Windows 10 (1809 or later) or Windows 11.
- The **ChatGPT** desktop app from the Microsoft Store: the current one, built on Codex (Store package `OpenAI.Codex`).
  The older **ChatGPT Classic** app is not supported, because it stores its data in one fixed folder.
- Windows PowerShell 5.1, which is built into Windows.

Tested with ChatGPT 26.1013.3656.0 on Windows 11 (build 26200).

## Open all accounts

For recurring startup or missing-icon problems, see [the diagnosis and troubleshooting notes](TROUBLESHOOTING.md).

After installing or upgrading, use **ChatGPT (All Accounts)** on your desktop or Start menu. It opens your primary account and every configured profile. Accounts with a visible window are skipped without activating or restarting them. An account running only in the background is reactivated and checked for a visible window, without restarting it. You can also run:

```powershell
& "$env:LOCALAPPDATA\Programs\tandem-chatgpt-desktop\chatgpt-profile.cmd" launch-all
```

This command opens independent account windows; it does not transfer or merge conversation history. Other profiles are still attempted if one fails, and failures are reported. Installers create the shortcuts automatically; use `-NoAllAccountsShortcut` to opt out. `-Root` selects which profile collection the shortcut opens. Uninstall removes its own All Accounts shortcuts while preserving links reassigned to another root.

## Install

Download this repository (**Code > Download ZIP**, then extract it) or clone it, then run the installer from its folder:

```powershell
git clone https://github.com/jiahaozhang2025/tandem-chatgpt-desktop.git
cd tandem-chatgpt-desktop
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This copies the scripts to `%LOCALAPPDATA%\Programs\tandem-chatgpt-desktop`. No admin rights needed. Run it again to upgrade; your profiles and shortcuts are kept.

## Quick start

```powershell
& "$env:LOCALAPPDATA\Programs\tandem-chatgpt-desktop\chatgpt-profile.cmd" new account2 -Label "Account 2"
```

A **ChatGPT (Account 2)** entry appears in the Start menu and on your desktop, with the ChatGPT logo in the profile's color. Open it and sign in with your second account. Your usual ChatGPT icon keeps opening your main account, and both can stay open together.

## Commands

| Command | What it does |
|---|---|
| `chatgpt-profile new <name> [-Label <text>] [-Color <color>] [-NoDesktopShortcut] [-NoStartMenuShortcut]` | Create a profile and its Start menu and desktop shortcuts. Running it on an existing profile keeps its data and refreshes the icon and shortcuts. |
| `chatgpt-profile launch <name>` | Open the profile's window, or bring it to the front if it's already open. This is what the shortcut runs. |
| `chatgpt-profile launch main` | Open the primary account using its normal data folders. |
| `chatgpt-profile taskbar [grouped\|separate] [-Disable]` | Save the taskbar grouping choice and update running windows and shortcuts. |
| `chatgpt-profile list` | Show profiles, whether each is running, and whether it has a saved login. |
| `chatgpt-profile stop <name>` | End the profile's instance and everything it started, like End task in Task Manager. Closing a ChatGPT window only hides it to the system tray; use the tray icon's Quit to exit normally. |
| `chatgpt-profile remove <name> [-KeepData] [-Force]` | Remove the profile's shortcuts and, unless `-KeepData`, its folder including its login. |
| `chatgpt-profile doctor [-Deep]` | Check that this PC and your ChatGPT version support side-by-side profiles. `-Deep` scans the app (a few seconds). |

Every command takes `-Root <folder>` to keep profiles somewhere other than `%USERPROFILE%\tandem-chatgpt-desktop`.
Colors: Orange, Blue, Green, Purple, Red, Teal, Pink, Gray.

The same commands are available as PowerShell functions (`New-ChatGPTProfile`, `Start-ChatGPTProfile`, `Get-ChatGPTProfile`, `Stop-ChatGPTProfile`, `Remove-ChatGPTProfile`, `Test-ChatGPTProfileSupport`, `Set-ChatGPTProfileTaskbar`) after `Import-Module "$env:LOCALAPPDATA\Programs\tandem-chatgpt-desktop\tandem-chatgpt-desktop"`.

## Taskbar grouping option

```powershell
# Separate colored icons for each account:
& "$env:LOCALAPPDATA\Programs\tandem-chatgpt-desktop\chatgpt-profile.cmd" taskbar separate
# Restore the app's normal grouped taskbar button:
& "$env:LOCALAPPDATA\Programs\tandem-chatgpt-desktop\chatgpt-profile.cmd" taskbar grouped
```

The choice is saved per profile root and survives future launches and upgrades. A fresh root uses normal grouping until separate mode is selected. Running `taskbar` without a mode selects separate mode; `taskbar -Disable` is an alias for grouped mode. Choose during installation with `install.ps1 -TaskbarMode Grouped` or `install.ps1 -TaskbarMode Separate`, optionally with `-Root`. Omitting that installer option preserves your existing choice.

Separate mode gives each account's windows and shortcuts a matching Windows taskbar identity and colored icon. It also creates **ChatGPT (Main)** to open the primary account. Pin the individual account shortcuts or running buttons if you want their icons available while closed. Windows keeps copies of pinned shortcuts; if a pin retains the old layout after changing modes, unpin it and pin the refreshed shortcut.

A hidden PowerShell helper maintains the separate identities on new windows. It exits after ChatGPT has been closed for 30 seconds. Grouped mode stops it and restores the live windows' previous taskbar properties without restarting ChatGPT. Both modes retain separate logins and data folders, and neither changes global taskbar settings. The native account shortcut reserves `main` when this option is configured; an older managed profile with that name must be renamed first.

## How it works

The ChatGPT app keeps its login and Codex state in the folder named by the `CODEX_HOME` environment variable, and its window and browser data in `CODEX_ELECTRON_USER_DATA_PATH`. It allows one running instance per data folder, so an instance with its own folders can run next to your main one.

Two Windows details make this harder than setting two variables:

- Store apps only run with their *package identity*, so you can't copy `ChatGPT.exe` out of the Store folder and run it.
- `Invoke-CommandInDesktopPackage` starts a program inside the package, but it passes command-line arguments, not environment variables.

So every launch writes a small `launch.cmd` into the profile folder and runs it with `cmd.exe` inside the package. `-PreventBreakaway` keeps everything `cmd.exe` starts inside the package too:

```
shortcut -> chatgpt-profile launch <name>          (hidden PowerShell)
  -> Invoke-CommandInDesktopPackage -PreventBreakaway   (inside the ChatGPT package)
    -> cmd.exe /d /c launch.cmd                         (sets CODEX_HOME and CODEX_ELECTRON_USER_DATA_PATH)
      -> ChatGPT.exe --user-data-dir=<profile>\electron
```

### Safety check

If the variables ever stop reaching the app, for example after an app update, it falls back to `%USERPROFILE%\.codex`, which is your main account's login. Two windows would then share one login without you noticing.

So after every launch, the tool waits up to 45 seconds for the app to write to the profile's own `CODEX_HOME`. If that doesn't happen, it closes the new window and shows an error instead. `chatgpt-profile doctor -Deep` tells you whether a new ChatGPT version still reads both variables.

## What's separate and what isn't

- **Separate per profile:** the login, local Codex state, settings, MCP servers, skills and plugins, remote connections, and window and browser data.
- **From your account:** chat history is stored by OpenAI per account, so it shows up after you sign in.
- **Shared:** the app itself. There is one Store install, and it updates as usual.
- **Taskbar:** choose normal grouping or separate colored account icons using the option above. Start menu and desktop shortcuts use the profile's colored logo in either mode.
- **Links and notifications** that open ChatGPT (such as `codex://` links) go to your main window.
- **Memory:** each window is a full instance of the app.

## Files

- Profiles: `%USERPROFILE%\tandem-chatgpt-desktop\<name>\`
  - `codex-home\`: login (`auth.json`) and local state
  - `electron\`: window and browser data
  - `profile.json`, `icon-<hash>.ico` (a new name whenever the icon changes, so Windows doesn't show a cached old one), `launch.cmd`, `launcher.log`
- Installed scripts: `%LOCALAPPDATA%\Programs\tandem-chatgpt-desktop\`
- Your main app's data (`%USERPROFILE%\.codex` and the app's own folders) is never touched.

To move profiles, stop them, move the folder, and run `chatgpt-profile new <name> -Root <new folder>` for each one to refresh its shortcut. The app updates the paths it stores in the profile on its next launch.

## Security notes

- Each profile's login is stored the same way the app stores your main one: in a file, `codex-home\auth.json`, readable by programs running as you. New profiles set `cli_auth_credentials_store = "file"` so the login stays inside the profile instead of a shared OS keyring entry.
- This tool makes no network requests and sends nothing anywhere.
- Shortcuts run `powershell.exe -ExecutionPolicy Bypass` for this one unsigned script. If your organization only allows signed scripts, sign them or don't use the shortcuts.

## Limitations

- It relies on app behavior that isn't documented, so a ChatGPT update can break it. The safety check stops a broken launch from sharing your main login, and `doctor -Deep` tells you whether a new version is still supported.
- The profile folder path must be ASCII-only and must not contain `%`, because `cmd.exe` can't pass those reliably. If your Windows user folder has other characters, use `-Root C:\tandem-chatgpt-desktop`.
- Windows only, and only the current ChatGPT app, not ChatGPT Classic.

Taskbar identity schema v2 also repairs icons owned by a previous helper process. Desktop, Start menu and private account links are refreshed on installation. If you retained an old pinned shortcut independently, repin the refreshed account shortcut to use the v2 identity.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\tandem-chatgpt-desktop\uninstall.ps1"
```

This removes the scripts and every profile's shortcuts, and keeps profile folders. Add `-RemoveProfiles` to also delete the profiles, including their logins, and `-Force` to skip the confirmation prompt.

## Prior art and credits

Others got here first; this project's difference is scope.

- **[Codex++](https://github.com/BigPizzaV3/CodexPlusPlus)** (AGPL-3.0): its Windows launcher uses the same in-package `cmd.exe` launch with `-PreventBreakaway`, and its "Codex multi-launch" runs one isolated instance per AI provider. It's a full enhancement app with provider switching and interface changes made by injecting scripts.
- **[cockpit-tools](https://github.com/jlcodes99/cockpit-tools)** (CC BY-NC-SA 4.0): an account manager for 16 AI coding tools. It can run several Codex/ChatGPT instances with different accounts in parallel, and adds quota monitoring and more.
- **[codex-multi-profile](https://github.com/Hung2124/codex-multi-profile)** by Hung2124: fast account switching inside one window, by swapping `auth.json`, controlled through a local debugging port.
- **[codex-multi-profile-windows](https://github.com/mkhlz/codex-multi-profile-windows)** and **[codex-multi-profile](https://github.com/niyu521/codex-multi-profile)**: earlier profile managers. The first copies the app out of the Store folder, which Hung2124's notes say stopped working once the app required its package identity. The second focuses on macOS.

Use one of those instead if you want one window with fast switching, quota dashboards, other AI providers, or many tools in one place. Use this one if all you want is a second account side by side, from code you can read in a few minutes.

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester .\tests
```

The tests mock the package, process and launch calls, so they never start ChatGPT or touch real profiles. CI runs PSScriptAnalyzer, plus Pester on both Windows PowerShell 5.1 and PowerShell 7.

## License

[MIT](LICENSE)
