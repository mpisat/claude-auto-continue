import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let output: String
}

// Only the installed bundle's existing Makefile is executed. No shell strings,
// credentials, model requests or Accessibility access are used by the menu app.
@MainActor final class MakeCommand {
    private var current: Process?
    private var deadline: Task<Void, Never>?

    func run(_ target: String) async -> CommandResult {
        guard current == nil, ["status", "start", "stop", "restart"].contains(target),
              let resources = Bundle.main.resourceURL else {
            return CommandResult(exitCode: 1, output: "Control command unavailable.")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        process.arguments = ["--no-print-directory", "-C", resources.path, target]
        process.standardOutput = output
        process.standardError = output
        current = process
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let result = CommandResult(exitCode: process.terminationStatus,
                                           output: String(decoding: data, as: UTF8.self))
                Task { @MainActor [weak self] in
                    self?.deadline?.cancel()
                    self?.deadline = nil
                    self?.current = nil
                    continuation.resume(returning: result)
                }
            }
            do {
                try process.run()
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let process = self?.current, process.isRunning else { return }
                    process.terminate()
                }
            } catch {
                current = nil
                continuation.resume(returning: CommandResult(exitCode: 1, output: error.localizedDescription))
            }
        }
    }
}
