import Darwin
import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

// Only the installed bundle's existing Makefile is executed. No shell strings,
// credentials, model requests or Accessibility access are used by the menu app.
@MainActor final class MakeCommand {
    private struct Invocation {
        let id: UUID
        let pid: pid_t
        let directory: URL
        let continuation: CheckedContinuation<CommandResult, Never>
    }

    private let resources: URL?
    private let timeout: Duration
    private var current: Invocation?
    private var deadline: Task<Void, Never>?

    init(resources: URL? = Bundle.main.resourceURL, timeout: Duration = .seconds(15)) {
        self.resources = resources
        self.timeout = timeout
    }

    func run(_ target: String) async -> CommandResult {
        guard current == nil, ["status", "start", "stop", "restart"].contains(target),
              let resources else {
            return CommandResult(exitCode: 1, output: "Control command unavailable.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-menu-\(UUID().uuidString)")
        let pid: pid_t
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            pid = try spawn(target, resources: resources, output: directory.appendingPathComponent("output"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return CommandResult(exitCode: 1, output: error.localizedDescription)
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            current = Invocation(id: id, pid: pid, directory: directory, continuation: continuation)
            // waitid leaves our child waitable. Its PID cannot be reused before
            // finish signals the dedicated process group and then reaps it.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var info = siginfo_t()
                var status: Int32
                repeat { status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while status == -1 && errno == EINTR
                let code = status == 0 ? (info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status) : 1
                Task { @MainActor [weak self] in self?.finish(id, exitCode: code) }
            }
            deadline = Task { @MainActor [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.finish(id, exitCode: 124, message: "Control command timed out. Check the watcher logs and refresh status.")
            }
        }
    }

    private func finish(_ id: UUID, exitCode: Int32, message: String? = nil) {
        guard let invocation = current, invocation.id == id else { return }
        current = nil
        deadline?.cancel()
        deadline = nil
        // POSIX_SPAWN_SETPGROUP created this group for this invocation only.
        // Kill descendants even if make exited first, before releasing its PID.
        kill(-invocation.pid, SIGKILL)
        let pid = invocation.pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
        // A regular file cannot block on pipe capacity or descendants retaining
        // stdout. Read only the final 64 KiB so verbose failures stay bounded.
        var output = ""
        if let file = try? FileHandle(forReadingFrom: invocation.directory.appendingPathComponent("output")) {
            defer { try? file.close() }
            if let size = try? file.seekToEnd() {
                try? file.seek(toOffset: size > 65536 ? size - 65536 : 0)
                if let data = try? file.read(upToCount: 65536) { output = String(decoding: data, as: UTF8.self) }
            }
        }
        try? FileManager.default.removeItem(at: invocation.directory)
        if let message { output += "\n" + message }
        invocation.continuation.resume(returning: CommandResult(exitCode: exitCode, output: output))
    }

    private func spawn(_ target: String, resources: URL, output: URL) throws -> pid_t {
        func check(_ status: Int32) throws {
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600))
        try check(posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO))
        let arguments: [UnsafeMutablePointer<CChar>?] = ["/usr/bin/make", "--no-print-directory", "-C", resources.path, target].map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for argument in arguments { free(argument) }
            for variable in environment { free(variable) }
        }
        guard arguments.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        var pid: pid_t = 0
        try arguments.withUnsafeBufferPointer { argv in
            try environment.withUnsafeBufferPointer { envp in
                // Both arrays contain at least their final null pointer.
                try check(posix_spawn(&pid, "/usr/bin/make", &actions, &attributes, argv.baseAddress!, envp.baseAddress!))
            }
        }
        return pid
    }
}
