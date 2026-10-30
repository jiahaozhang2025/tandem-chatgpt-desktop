# Recurring launch and icon problems

## Diagnosis on October 29, 2026

Two separate launcher defects caused the reported symptoms. Neither required changing account settings or deleting login data.

1. **Missing Main and All Accounts icons after app updates.** These shortcuts stored an icon location inside a versioned Microsoft Store package directory. When Windows removed the old package, the shortcut's executable launcher still existed but its icon resource did not. Refreshing shortcuts with another package path only postponed the next failure. These icons now live in the local profile root, outside the vendor package. Old icon hashes remain available for pinned shortcut copies.
2. **All Accounts reported an invisible account as open.** The second account's desktop process, renderers and profile writes existed, but its normal app window was hidden. The old command checked only for a running process and returned AlreadyRunning without sending an activation request. Reproducing that command left zero visible windows for the account. A normal account-specific launch then revealed the existing window with the same process ID. The updated command distinguishes a visible taskbar window from a background process and sends the normal activation request when needed. It waits for a window rather than assuming that profile writes mean the account is usable.

Background processes can outlive their windows; this is not proof of a crash. The evidence establishes the hidden state and the failed skip decision, not which user action hid the window. Separate account processes and their selected data folders continued to work on the installed Store version 26.1027.3384.0.

## What to use

Use **ChatGPT (All Accounts)** to open missing account windows. Visible or minimized windows are left alone; hidden background accounts are reactivated. The command never merges conversations or restarts healthy accounts just to reveal a window.

Reinstalling the companion launcher repairs its Main and All Accounts shortcuts with durable icons and refreshes its shell helper without restarting ChatGPT. This preserves the grouped/separate taskbar choice. `-NoAllAccountsShortcut` opts out of this shortcut and helper maintenance.

## Evidence for a future failure

Look in `%USERPROFILE%\tandem-chatgpt-desktop`:

* `launcher-events.log`: JSON lines recording each account's Visible, Hidden or Stopped state, action and process IDs during All Accounts use. Hidden + Activate should be followed by Visible + Ready. A Failed event means a window was not verified or startup failed; the command also reports an error.
* `<profile>\launcher.log`: installed app version, whether its process already existed, startup verification and errors.
* `taskbar.log`, if present: errors applying separate taskbar identities. This is distinct from an app failing to create a window.

The new tests reproduce a background process without a window and an old package disappearing. Earlier process-only tests and checking already visible windows did not cover those cases. Window activation can still fail for another reason; an initialized process is left running on visibility timeout rather than being silently killed or reported as successfully opened.

## Correct icon file but a stale displayed image

Rewriting shortcut metadata alone can leave another Explorer view showing an old cached image. The launcher now sends a targeted SHCNE_UPDATEITEM notification with SHCNF_PATHW and SHCNF_FLUSH after shortcut creation or icon updates. It does not delete Windows icon databases or restart Explorer. If an icon still differs between Desktop, Start and taskbar, identify the affected surface: pinned copies and native app shortcuts can be distinct from the companion shortcuts.

Native test windows now verify actual Windows visibility transitions and tool-window filtering. These regression checks exercise the causes observed here; they cannot prove that all future app or Windows releases will behave identically.
