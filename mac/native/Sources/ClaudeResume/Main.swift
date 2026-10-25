import AppKit
import Darwin
import DesktopAX
import Foundation
import ResumeCore

private struct Options {
    var command = "doctor"
    var dryRun = false
    var metadata: URL
    var projects: URL
    var stateDirectory: URL
    var selected: Set<String> = []
    init(_ arguments: [String]) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        metadata = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        projects = home.appendingPathComponent(".claude/projects")
        stateDirectory = home.appendingPathComponent("Library/Application Support/Claude Auto Continue")
        var index = 0
        if let first = arguments.first, !first.hasPrefix("--") { command = first; index = 1 }
        while index < arguments.count {
            let key = arguments[index]; index += 1
            if key == "--dry-run" { dryRun = true; continue }
            guard ["--metadata-root", "--projects-root", "--state-dir", "--session"].contains(key), index < arguments.count else {
                throw CLIError.usage
            }
            let value = arguments[index]; index += 1
            switch key {
            case "--metadata-root": metadata = URL(fileURLWithPath: value)
            case "--projects-root": projects = URL(fileURLWithPath: value)
            case "--state-dir": stateDirectory = URL(fileURLWithPath: value)
            case "--session": selected.insert(value)
            default: break
            }
        }
        guard ["doctor", "list", "diagnose", "once", "watch", "request-permission", "help"].contains(command) else { throw CLIError.usage }
        if ["watch", "once"].contains(command) && !dryRun && selected.isEmpty { throw CLIError.usage }
    }
}
private enum CLIError: Error { case usage, alreadyRunning, unsafeLock }

// This lock is an ownership fence across helper processes, not a data mutex.
// It intentionally spans the bounded AX action so two invocations cannot retry
// the same turn. Desktop's native scheduler does not participate in this fence.
private final class ProcessLock {
    private let fd: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fd = open(directory.appendingPathComponent("watcher.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CLIError.unsafeLock }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw CLIError.alreadyRunning }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

@MainActor private final class FilteredSessions: SessionSource {
    let base: FileSessionSource
    let selected: Set<String>
    init(_ options: Options) { base = FileSessionSource(metadataRoot: options.metadata, projectsRoot: options.projects); selected = options.selected }
    func discover() throws -> [Session] {
        try base.discover().filter { selected.isEmpty || selected.contains($0.id) }
    }
}

@MainActor private final class Runner {
    let options: Options
    let source: FilteredSessions
    let transcripts = FileTranscriptSource()
    let store: AtomicStateStore
    let desktop: Desktop
    let coordinator: ResumeCoordinator
    var timer: Timer?
    var task: Task<Void, Never>?
    var signals: [DispatchSourceSignal] = []
    var ownership: ProcessLock?
    var previous: [SessionResult] = []
    init(_ options: Options) {
        self.options = options
        source = FilteredSessions(options)
        store = AtomicStateStore(url: options.stateDirectory.appendingPathComponent("state.json"))
        desktop = Desktop(transcripts: transcripts)
        coordinator = ResumeCoordinator(sessions: source, transcripts: transcripts, state: store, ui: desktop, nativeGrace: 120)
    }
    func emit(_ fields: [String: Any]) {
        var fields = fields
        fields["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
    func describe(_ result: SessionResult) -> String {
        switch result.outcome {
        case .blocked(let reason): return "blocked_" + reason.rawValue
        case .attempted(let outcome): return "attempt_" + outcome.rawValue
        default: return String(describing: result.outcome)
        }
    }
    func list() throws {
        for session in try source.discover() {
            var data: [String: Any] = ["session": session.id, "project": URL(fileURLWithPath: session.cwd).lastPathComponent]
            switch try transcripts.latest(session) {
            case .limited(let event):
                data["status"] = event.resetsAt > Date() ? "waiting" : "due"
                data["reset"] = ISO8601DateFormatter().string(from: event.resetsAt)
            case .assistant: data["status"] = "assistant_progress"
            case .human: data["status"] = "newer_prompt"
            case .unavailable: data["status"] = "unknown"
            }
            emit(data)
        }
    }
    func tick() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await coordinator.runOnce(dryRun: options.dryRun)
            if results != previous {
                for result in results where !previous.contains(result) {
                    emit(["session": result.sessionID, "outcome": describe(result)])
                }
                previous = results
            }
            await desktop.restore((try? source.base.discover()) ?? [])
            task = nil
        }
    }
    func startWatch() throws {
        ownership = try ProcessLock(directory: options.stateDirectory)
        emit(["event": "watcher_started", "dryRun": options.dryRun, "accessibility": Desktop.trusted])
        // Desktop has no supported external event feed. Each sweep checks file
        // signatures, scans only changed tails, and writes state only on change.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: number, queue: .main)
            signalSource.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.timer?.invalidate(); self?.task?.cancel()
                    self?.emit(["event": "watcher_stopped"])
                    exit(0)
                }
            }
            signalSource.resume(); signals.append(signalSource)
        }
        tick()
    }
    func run() async -> Int32? {
        do {
            switch options.command {
            case "help":
                print("ClaudeResume doctor|list|diagnose|once|watch|request-permission [--dry-run] [--session local_ID] [--metadata-root PATH] [--projects-root PATH] [--state-dir PATH]")
            case "request-permission":
                Desktop.requestPermission()
                emit(["accessibility": Desktop.trusted, "action": "Enable Claude Auto Continue in System Settings > Privacy & Security > Accessibility if required"])
                // Keep the app alive briefly so the system can register its stable identity.
                try await Task.sleep(for: .seconds(2))
            case "doctor":
                let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first
                let version = app?.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "not_running"
                emit(["accessibility": Desktop.trusted, "desktopVersion": version, "localSessions": try source.discover().count,
                      "metadataExists": FileManager.default.fileExists(atPath: options.metadata.path), "stateDirectory": options.stateDirectory.path])
            case "list": try list()
            case "diagnose":
                ownership = try ProcessLock(directory: options.stateDirectory)
                let sessions = try source.discover()
                for session in sessions {
                    let readiness = await desktop.diagnose(session)
                    emit(["session": session.id, "readiness": readiness.rawValue, "diagnostic": desktop.lastDiagnostic])
                }
                await desktop.restore((try? source.base.discover()) ?? [])
            case "once":
                ownership = try ProcessLock(directory: options.stateDirectory)
                let results = await coordinator.runOnce(dryRun: options.dryRun)
                for result in results { emit(["session": result.sessionID, "outcome": describe(result)]) }
                await desktop.restore((try? source.base.discover()) ?? [])
                if results.contains(where: { $0.outcome == .failed }) { return 1 }
            case "watch": try startWatch(); return nil
            default: throw CLIError.usage
            }
            return 0
        } catch {
            emit(["event": "error", "reason": String(describing: error)])
            return 1
        }
    }
}

@main struct Main {
    @MainActor static func main() {
        umask(0o077)
        setbuf(stdout, nil)
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let runner = Runner(options)
            Task { @MainActor in if let status = await runner.run() { exit(status) } }
            app.run()
            withExtendedLifetime(runner) {}
        } catch {
            print("Invalid arguments. Run ClaudeResume help.")
            exit(2)
        }
    }
}
