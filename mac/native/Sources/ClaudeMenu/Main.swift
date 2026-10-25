import AppKit

@MainActor final class MenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let command = MakeCommand()
    private var snapshot = MenuSnapshot(state: .unavailable)
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private let status = NSMenuItem(title: "Checking status...", action: nil, keyEquivalent: "")
    private let login = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var start: NSMenuItem!
    private var stop: NSMenuItem!
    private var restart: NSMenuItem!
    private var quit: NSMenuItem!

    override init() {
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Claude Auto Continue", action: nil, keyEquivalent: ""))
        menu.addItem(status); menu.addItem(login); menu.addItem(.separator())
        start = add("Start Watcher", #selector(startWatcher), to: menu)
        stop = add("Stop Watcher", #selector(stopWatcher), to: menu)
        restart = add("Restart Watcher", #selector(restartWatcher), to: menu)
        menu.addItem(.separator())
        _ = add("Refresh Status", #selector(refreshStatus), to: menu)
        _ = add("Open Logs", #selector(openLogs), to: menu)
        _ = add("Accessibility Settings", #selector(openSettings), to: menu)
        _ = add("Instructions", #selector(openInstructions), to: menu)
        menu.addItem(.separator())
        quit = add("Quit Menu Bar (watcher keeps running)", #selector(quitMenu), to: menu)
        item.menu = menu
        item.isVisible = true
        item.button?.title = "AC"
        item.button?.imagePosition = .imageLeft
        item.button?.setAccessibilityLabel("Claude Auto Continue")
        render()
        refreshStatus()
        // launchd offers no supported job-change feed. One read every 15 seconds
        // keeps the icon current after external Makefile controls; no state writes.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    private func render() {
        let busy = operation != nil
        let message: String
        let symbol: String
        switch snapshot.state {
        case .running: message = "Running - \(snapshot.sessionCount ?? 0) sessions"; symbol = "arrow.clockwise.circle"
        case .stopped: message = "Stopped"; symbol = "pause.circle"
        case .notInstalled: message = "Watcher not installed"; symbol = "exclamationmark.circle"
        case .unavailable: message = "Status unavailable"; symbol = "questionmark.circle"
        }
        status.title = busy ? "Updating..." : message
        status.isEnabled = false
        login.title = snapshot.startsAtLogin.map { "Start at login: " + ($0 ? "On" : "Off") } ?? "Start at login: Unknown"
        login.isEnabled = false
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: message)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Claude Auto Continue: " + message
        start.isEnabled = !busy && snapshot.state == .stopped
        stop.isEnabled = !busy && snapshot.canStopWatcher
        restart.isEnabled = !busy && [.running, .stopped].contains(snapshot.state)
        quit.isEnabled = !busy
    }

    func menuWillOpen(_ menu: NSMenu) { refreshStatus() }

    @objc private func refreshStatus() { perform("status") }
    @objc private func startWatcher() { perform("start") }
    @objc private func stopWatcher() { perform("stop") }
    @objc private func restartWatcher() { perform("restart") }

    private func perform(_ target: String) {
        guard operation == nil else { return }
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            let previous = snapshot
            let result = await command.run(target)
            if target == "status" {
                snapshot = MenuSnapshot.parse(exitCode: result.exitCode, output: result.output)
            } else {
                let fresh = await command.run("status")
                snapshot = MenuSnapshot.parse(exitCode: fresh.exitCode, output: fresh.output)
            }
            operation = nil
            render()
            if snapshot != previous || target != "status" {
                print("Menu status: \(snapshot.state); sessions: \(snapshot.sessionCount ?? 0); login: \(snapshot.startsAtLogin.map(String.init) ?? "unknown"); command: \(target); exit: \(result.exitCode)")
                fflush(stdout)
            }
            if target != "status", result.exitCode != 0 {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Could not \(target) the watcher"
                alert.informativeText = String(result.output.suffix(2000))
                alert.runModal()
            }
        }
        render()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude Auto Continue"))
    }
    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc private func openInstructions() {
        if let url = Bundle.main.url(forResource: "CONTROL", withExtension: "md") { NSWorkspace.shared.open(url) }
    }
    @objc private func quitMenu() {
        guard operation == nil else { return }
        timer?.invalidate()
        NSApp.terminate(nil)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuController?
    func applicationDidFinishLaunching(_ notification: Notification) { controller = MenuController() }
}

@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { return }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
