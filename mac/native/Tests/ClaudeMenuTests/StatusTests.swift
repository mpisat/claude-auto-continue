import Testing
@testable import ClaudeMenu

@Test func runningStatus() {
    let status = MenuSnapshot.parse(exitCode: 0, output: "Watcher: ON (PID 123)\nStart at login: ON\nSelected sessions: 5\n")
    #expect(status.state == .running)
    #expect(status.startsAtLogin == true)
    #expect(status.sessionCount == 5)
}

@Test func stoppedStatus() {
    let status = MenuSnapshot.parse(exitCode: 0, output: "Watcher: OFF (not loaded)\nStart at login: OFF\nSelected sessions: 5\n")
    #expect(status.state == .stopped)
    #expect(status.startsAtLogin == false)
    #expect(status.sessionCount == 5)
}

@Test func loadedButNotRunningIsStopped() {
    let status = MenuSnapshot.parse(exitCode: 0, output: "Watcher: NOT RUNNING (loaded, state: waiting)\nStart at login: ON\nSelected sessions: 5\n")
    #expect(status.state == .stopped)
    #expect(status.startsAtLogin == true)
}

@Test func missingInstallation() {
    #expect(MenuSnapshot.parse(exitCode: 0, output: "Watcher: NOT INSTALLED\nSee mac/README.md for installation.\n").state == .notInstalled)
}

@Test func failedCommandCannotClaimRunning() {
    #expect(MenuSnapshot.parse(exitCode: 2, output: "Watcher: ON (PID 123)\nStart at login: ON\nSelected sessions: 5\n").state == .unavailable)
}

@Test(arguments: [
    "",
    "Watcher: ON (PID 123)\n",
    "Watcher: ON (PID 0)\nStart at login: ON\nSelected sessions: 5\n",
    "Watcher: ON (PID 123)\nStart at login: UNKNOWN\nSelected sessions: 5\n",
    "Watcher: ON (PID 123)\nStart at login: ON\nSelected sessions: -1\n",
    "Watcher: UNKNOWN\nStart at login: ON\nSelected sessions: 5\n"
]) func incompleteOrUnknownOutputCannotClaimRunning(_ output: String) {
    #expect(MenuSnapshot.parse(exitCode: 0, output: output).state == .unavailable)
}

@Test func stopRemainsAvailableForLoadedWaitingJob() {
    let status = MenuSnapshot.parse(exitCode: 0, output: "Watcher: NOT RUNNING (loaded, state: waiting)\nStart at login: ON\nSelected sessions: 5\n")
    #expect(status.canStopWatcher)
}

@Test func stopRequiresAnInstalledWatcher() {
    #expect(MenuSnapshot(state: .running).canStopWatcher)
    #expect(!MenuSnapshot(state: .notInstalled).canStopWatcher)
    #expect(!MenuSnapshot(state: .unavailable).canStopWatcher)
}
