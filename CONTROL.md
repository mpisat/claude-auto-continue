# Control Claude Auto Continue

Open Terminal and enter this folder:

```bash
cd /Users/muratpisat/Documents/Developer/vibe/claude-auto-continue
make
```

`make` shows the available controls. The installed watcher runs in the background; this version uses these folder controls and has no menu-bar icon.

| Command | What it does |
| --- | --- |
| `make status` | Shows ON/OFF, whether it starts at login, and the number of selected sessions. |
| `make start` | Starts the watcher and enables it at future logins. Safe to run when already running. |
| `make stop` | Stops the watcher and keeps it off across logins until you run `make start`. |
| `make restart` | Stops and starts the watcher. Enables it at future logins. |
| `make logs` | Shows recent activity and follows both logs. Press Ctrl-C to stop viewing; the watcher keeps running. |
| `make doctor` | Checks discovery and permissions for this foreground invocation. |
| `make sessions` | Lists available Code sessions; it does not change the selected sessions. |

For example:

```text
Watcher: ON (PID 12345)
Start at login: ON
Selected sessions: 5
```

`ON` means the background process is running. It still needs Claude Desktop open and Accessibility access to operate. Enable the exact Claude Auto Continue.app entry in System Settings → Privacy & Security → Accessibility. A foreground `make doctor` permission result alone does not establish the background process's permission; its startup record in `make logs` reports `accessibility` and `dryRun`.

In the activity log, `waiting` means a selected session has a qualifying limit and is waiting for reset plus the two-minute grace. `ineligible` means its current transcript does not qualify for retry. Logs record state changes, so unchanged waiting sessions do not generate a new line every 15 seconds. A click or an `attempt_...` log entry is not proof of successful resumption.

Start, stop and restart preserve the selected sessions, attempt ledger and logs. They control only this helper. Claude's native auto-continue setting stays as you left it, so stopping this helper does not turn off native auto-continue.

The installed app is in `~/Applications/Claude Auto Continue.app`; state is in `~/Library/Application Support/Claude Auto Continue`; logs are in `~/Library/Logs/Claude Auto Continue`. These commands need no sudo and do not rebuild or reinstall the app, avoiding unnecessary Accessibility reauthorization.

For first installation, selecting a different session set or uninstalling, see [the macOS guide](mac/README.md). Controls require the installed native macOS watcher and macOS's built-in `make` (Command Line Tools).
