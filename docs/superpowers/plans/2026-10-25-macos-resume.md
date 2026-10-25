# macOS multi-session resume implementation plan

Goal: resume existing local Claude Desktop Code sessions after a confirmed five-hour limit resets, without duplicating turns or resuming completed work.

Approved requirements: the owner's pasted task plus explicit instruction to implement, install, and validate. Work on macos-multi-session in the owner's fork; do not change Windows or CLI behavior.

Snapshot: upstream b50d1da, clean checkout before implementation. The existing macOS scripts only perform manual window scans. Current Desktop 3.6556.2 exposes sidebar session buttons, the active local session ID in AXURL, an empty Prompt field, and a Session limit reached card containing Try again.

Architecture: a dependency-free Swift package contains a tested discovery/coordinator library and a native Accessibility adapter. Read structured local session metadata and the newest relevant transcript record; never use stale saved auto-resume preferences as evidence. Use Accessibility only for session selection and the exact retry button within its limit card. A user LaunchAgent runs the installed helper. Polling is required because Desktop supplies no supported external event feed; unchanged transcript files are cached and state is written only on change.

1. Build the core with tests first: discover non-archived local sessions; scan JSONL backward without loading whole history; accept only a latest top-level five_hour error with a reset. Ignore sidechains and task notifications, but cancel eligibility on any newer meaningful user turn, including native continuation, or normal assistant output. Test malformed data and partial appends.
2. Coordinate one session at a time: wait for reset, re-read evidence after navigation, reject drafts/busy/wrong sessions, persist attempts before UI action, verify progress by a newer normal assistant record, and distinguish delivered from unconfirmed. Retry only definitely unsent actions with bounded backoff; never replay an ambiguous send automatically. Use an exclusive process lock across active runs and atomic state saves.
3. Implement and test the AX adapter's structural matching against captured/synthetic trees: exact session identity, unique sidebar navigation, exact limit card, no generic Continue matching. Fail closed on unknown layouts. Bound each traversal and wait. Do not log conversation text or read credentials.
4. Add list, dry-run, once, watch, doctor, and diagnostics commands. Add build/install/uninstall scripts, a stable signed app bundle, and LaunchAgent. Uninstall unloads the agent and removes only this tool's files. Preserve existing manual scripts for compatibility, documenting their limits.
5. Run automated tests (including production coordinator tests with five sessions and negative cases), existing CLI tests, native build, and a read-only live dry-run on all five sessions. Exercise real retries only after the real reset; do not generate quota-consuming fixtures. Record precisely which live checks succeed and any Accessibility permission or real-reset gate still pending.
6. Review the complete diff, resolve findings, commit and push macos-multi-session to the owner's fork. The dedicated branch is the requested delivery target; do not merge upstream or publish a release.

Verification: swift test --package-path mac/native; bash tests/test.sh; bash -n mac/build-native.sh mac/install-watcher.sh; live doctor/list/once --dry-run. Five-session real resumption requires the actual five-hour reset; simulated tests do not establish it.

Owner steering during implementation: keep native auto-continue enabled. The executable uses a two-minute fallback grace. Its process fence excludes only helper instances; native/manual input is revalidated before action, but atomic exclusion with Desktop's independent native sender is not available. Do not claim that guarantee. Live navigation revealed the native checkbox and countdown, both preserved.
