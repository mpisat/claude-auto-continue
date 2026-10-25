# Claude Desktop auto-resume on macOS

The native watcher resumes selected existing local Code-tab sessions after a confirmed five-hour usage limit resets. It uses Swift and macOS Accessibility. It does not launch replacement CLI conversations.

## Everyday controls

Use the Makefile in the repository root. See [CONTROL.md](../CONTROL.md) for the short guide.

```bash
make status
make stop
make start
make logs
```

`make stop` also disables startup at future logins; `make start` enables it again. These controls preserve the installed session selection, attempt ledger, logs and Claude's native auto-continue preference.

## Build and inspect

Requires macOS 13 or later and an installed Swift 6 toolchain (Xcode or Command Line Tools). There are no third-party package dependencies.

```bash
bash mac/build-native.sh
"mac/native/.build/Claude Auto Continue.app/Contents/MacOS/ClaudeResume" doctor
"mac/native/.build/Claude Auto Continue.app/Contents/MacOS/ClaudeResume" list
```

`list` prints session IDs, project names and the latest local transcript status. It does not print prompts, responses or credentials. `doctor` reports Accessibility permission, Desktop version and discovery status.

Choose the actual sessions to monitor. Explicit selection prevents an old, non-archived conversation from being restarted merely because its history ends in a limit error.

```bash
bash mac/install-watcher.sh \
  --session local_YOUR_FIRST_SESSION_UUID \
  --session local_YOUR_SECOND_SESSION_UUID
```

Repeat `--session` for any number of sessions. Run the installer again with the complete desired list to update it. IDs remain valid across title changes. The watcher never changes Claude's native auto-continue preference.

The installed application is `~/Applications/Claude Auto Continue.app`. Its user LaunchAgent is `~/Library/LaunchAgents/io.github.claude-ac.macos-watcher.plist`. No sudo is required.

If the helper lacks Accessibility permission, run:

```bash
open "$HOME/Applications/Claude Auto Continue.app" --args request-permission
```

Enable Claude Auto Continue in System Settings > Privacy & Security > Accessibility. A locally rebuilt, ad-hoc signed application may need permission re-enabled. Do not grant unrelated applications access.

## Commands

```bash
watcher="$HOME/Applications/Claude Auto Continue.app/Contents/MacOS/ClaudeResume"
"$watcher" list
"$watcher" once --dry-run --session local_YOUR_SESSION_UUID
"$watcher" diagnose --session local_YOUR_SESSION_UUID
"$watcher" once --session local_YOUR_SESSION_UUID
```

`once --dry-run` evaluates transcript eligibility without navigating, clicking or changing the attempt ledger. `diagnose` additionally visits the selected sessions, checks the current UI and restores the original session when it is safe; it never presses Retry. `once` performs eligible retries. `watch` runs the same coordinator every 15 seconds. Actual `once` and `watch` require an explicit session selection.

The LaunchAgent owns the same exclusive process lock as manual action commands. If it is running, `once` and `diagnose` fail with `alreadyRunning` rather than running competing controllers. `doctor`, `list` and `help` remain available. To temporarily unload it:

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/io.github.claude-ac.macos-watcher.plist"
```

Restore it with the corresponding `launchctl bootstrap` command and the same arguments. `--metadata-root`, `--projects-root` and `--state-dir` support explicitly chosen storage locations; normally the defaults suffice.

## Retry behavior

1. Discover selected non-archived local Desktop sessions from their metadata. Resolve each actual CLI session ID to a unique local transcript.
2. Read backward to the newest meaningful top-level transcript event. Only an explicit rejected `five_hour` rate-limit record with a numeric reset qualifies. Later user/automatic continuation messages, normal assistant progress, other errors and unknown data suppress retry. Known metadata, tool results and task notifications are excluded from that decision.
3. Wait until two minutes after the reset, giving native auto-continue its first opportunity. There is no age expiry that discards an overnight missed reset.
4. Select the exact sidebar entry and verify the resulting local session ID through its Accessibility URL. Duplicate labels, unknown layouts, incomplete Accessibility reads, dialogs, busy controls, drafts and pending file attachments block the action.
5. Re-read transcript evidence, persist the attempt, then obtain a fresh retry button inside the session's actual Session limit reached card. No generic Continue matching, coordinate clicking, prompt insertion or clipboard manipulation is used.
6. Verify progress from a later genuine assistant record. A click alone is recorded as attempted, not successful.

An ambiguous or delivered click is never automatically repeated for the same limit event, including after a crash or reinstall. A definitely unsent attempt or a new explicit rate-limit rejection can retry with 30/60-second backoff, at most three attempts per session/reset. A new reset window has its own count.

Native auto-continue remains enabled if you enabled it. The final UI/transcript checks suppress activity already visible from native or manual continuation, but Desktop's independent sender does not share the helper's lock. Keeping both enabled cannot provide an atomic no-duplicate guarantee. The two-minute grace reduces that overlap; it does not prove native has permanently stopped trying.

## State, logs and privacy

State: `~/Library/Application Support/Claude Auto Continue/state.json`.
Logs: `~/Library/Logs/Claude Auto Continue/watcher.log` and `watcher-error.log`.

Logs contain session IDs, timestamps, decisions and statuses. The helper reads local session metadata and transcript records, but never logs their conversation content or reads credential stores. It has no HTTP client, telemetry, listener or purchase/upgrade actions. Pressing Retry naturally allows Claude Desktop to make its normal model requests and perform the user's existing task.

Unchanged files are cached. Each changed transcript scan reads at most 8 MiB from the tail; if that does not establish a meaningful event, the result is unknown and no action occurs. Accessibility traversals and selection waits are bounded. One failing session does not abort processing of the others.

The adapter was inspected against Claude Desktop 3.6556.2 in English. Unknown/localized layouts fail closed and need a new captured fixture before adding support. Collapsed or hidden sidebar entries may be unavailable; the helper will not guess another session by coordinates.

## Tests and real validation

```bash
swift test --package-path mac/native
bash tests/test.sh
bash -n mac/build-native.sh mac/install-watcher.sh
```

Tests include five-session coordinator execution with real local fixtures, weekly/future limits, new human/native input, restart replay prevention, state-save failure, ambiguous sends, retry exhaustion, relocation, malformed/partial transcript data and Accessibility safety predicates. They do not send model requests.

Read-only live diagnostics establish discovery, navigation, identity and card recognition. Successful unattended resumption must additionally be observed after a real reset; unit tests and a successful build do not establish that. See `VALIDATION.md` for the recorded local validation.

## Uninstall

```bash
bash mac/install-watcher.sh --uninstall
```

This unloads the LaunchAgent and removes this helper's app and plist. It leaves Claude Desktop, its settings and conversations untouched. The attempt ledger and logs are deliberately retained: reinstalling must not replay an uncertain click. Their locations are listed above.

## Older manual scripts

`resume-now.sh`, `resume-picker.sh` and `make-shortcut-mac.sh` remain available for compatibility. They use the older window/button heuristics, are not the native watcher, and are not suitable for unattended multi-session resumption. The Windows and CLI implementations are unchanged.
