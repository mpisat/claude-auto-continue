# Local macOS validation

Validated on 2026-10-25 against Claude Desktop 3.6556.2, embedded Claude Code 2.1.308, Apple Silicon, and Swift 6.4. Work is on the dedicated macos-multi-session branch in the owner's fork.

## Observed results

- Native package: 51 tests passed (34 core/production-boundary tests and 17 Accessibility tests).
- Existing CLI suite: 31 tests passed.
- Native build: release app built and ad-hoc signed successfully.
- Installer: plist syntax validated; application and user LaunchAgent installed for five explicitly selected sessions.
- Shell syntax and shellcheck warning-level checks passed for both new scripts.
- Live read-only discovery and navigation visited all five selected sessions and verified their local identities. Two currently limited sessions exposed a recognized Retry card; the other three were not eligible and were left alone.
- Live diagnostics verified restoration to an original conversation outside the diagnostic's selected set. No prompts were sent during these checks.
- A real-process dry-run smoke test verified watcher startup, rejection of a competing action process, no attempt-ledger writes, and clean termination of the owned test process.
- Review defects were reproduced before fixing: unreadable prompt treated as empty, attachments and uncertain Stop state not blocking, stale transcript relocation/uniqueness, and limit evidence changing during persistence. Corresponding tests now pass. Restoration was additionally reproduced and verified against the actual app.

## Native coexistence

The owner explicitly chose to retain Claude's native auto-continue setting. The helper waits two minutes past the recorded reset and validates current transcript/UI state before retrying. It does not claim atomic exclusion with Desktop's independent sender. Its own process lock, durable event fingerprint and conservative ambiguous-send policy prevent competing helper instances or watcher restarts from blindly repeating the same event.

## Remaining live gate

Actual unattended five-session resumption after a real reset has not yet been observed. The selected sessions currently have different live states, so resuming completed sessions just to make a five-session demonstration would violate the safety contract. The next currently recorded limit resets at 11:50 Bangkok on 2026-10-25; fallback eligibility begins at 11:52 if the native mechanism has not already resumed the task.

The installed LaunchAgent initially reported Accessibility permission false under its background identity. The owner authorized enabling the exact installed helper entry and completed macOS authentication. The Accessibility UI then showed Claude Auto Continue.app enabled. After restarting only this LaunchAgent, its own background log reported accessibility true at 10:23:26 Bangkok; launchctl confirmed the process running. Foreground diagnostics alone were not used as proof of background authorization.

No Cloudflare validation, synthetic model requests, credit purchases, plan changes, credential-store reads, or conversation uploads were performed.

## Folder controls validation

The owner requested a Makefile with instructions or a menu-bar launcher. The repository-root Makefile and CONTROL.md provide the requested folder controls without changing the installed native executable.

Live control checks on 2026-10-25 exercised the production Makefile against only this helper's LaunchAgent:

- Stop unloaded the service and set its persistent login-disable flag. Repeated stop was safe.
- Start loaded a running process and cleared the disable flag. Repeated start retained the same PID.
- Restart waited for unload, then started a different PID. Both transition waits have a five-second bound.
- Status correctly reported ON, OFF, login enablement, five selected sessions, and a missing installation. This Mac emits enabled/disabled values from print-disabled; the status reader also recognizes boolean values. The initial disabled-status assertion failed before correcting that parser.
- Missing app and plist start attempts failed with the installation error before changing the running process.
- Doctor and session listing executed through their Makefile targets.
- The log target followed both actual logs. Ctrl-C closed the viewer and left the watcher PID unchanged.
- The installed plist and attempt ledger were byte-for-byte unchanged by the control sequence. Fresh background startup again reported Accessibility true and dryRun false.
- GNU Make 3.81 executed the targets. Expanded recipes passed bash syntax validation and ShellCheck at warning severity.

The watcher was left running with startup at login enabled. This validation does not change the real-reset acceptance gate above.

## Menu-bar app validation

The owner explicitly requested the missing tray icon. A separate native menu app now controls the same installed watcher through a bundled copy of the tested Makefile. It remains visible when the watcher is stopped, starts at login independently, and adds status, Start/Stop/Restart, logs, Accessibility settings and instructions. Quitting the menu app leaves the watcher running. One status read every 15 seconds is needed because launchd supplies no supported job-change feed for external Makefile controls; unchanged status produces no log writes.

- Status interpretation tests failed on the initial stub, then passed for running, stopped, loaded-but-not-running, missing installation, command failure and incomplete/unknown output.
- The full native test suite passed with the menu executable included. The menu release build, strict signature verification, script syntax checks, ShellCheck and expanded Makefile recipe checks passed.
- The installed menu app's background log reported running, five sessions, login enabled and status-command exit zero. Its error log was empty. The owner confirmed the tray icon was visible.
- The native UI automation tool could not attach to this windowless menu app. Direct automated clicks on menu items remain unverified; the shared Start/Stop/Restart commands were exercised in the folder-controls validation above.
- Both LaunchAgents were running. The original watcher PID remained unchanged during menu installation, and its executable hash still matched the original build, preserving its Accessibility identity. Menu installation does not rebuild or replace that watcher.
- The menu installer packages its own control Makefile and instructions, so it does not depend on the source folder remaining at the original location. Fresh watcher installs include the menu app; uninstall removes both apps and retains the attempt ledger and logs.

Real unattended post-reset resumption remains subject to the acceptance gate above.
