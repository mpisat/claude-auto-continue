import Foundation
import Testing
@testable import ClaudeMenu

@Suite(.serialized) @MainActor struct CommandTests {
    private func fixture(_ recipe: String) throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("claude-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "SHELL := /bin/bash\nstatus:\n\t@\(recipe)\n".write(to: url.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        return url
    }

    @Test func timeoutCompletesWithoutWaitingForDescendantOutput() async throws {
        let url = try fixture("trap '' TERM; echo started; sleep 2; echo late > late-marker")
        defer { try? FileManager.default.removeItem(at: url) }
        let command = MakeCommand(resources: url, timeout: .seconds(1))
        let start = ContinuousClock.now
        let result = await command.run("status")
        #expect(start.duration(to: .now) < .milliseconds(1500))
        #expect(result.exitCode == 124)
        #expect(result.output.contains("timed out"))
        #expect(result.output.contains("started"))
        try await Task.sleep(for: .milliseconds(2200))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("late-marker").path))
        let next = await command.run("unknown")
        #expect(next.exitCode == 1)
        #expect(next.output == "Control command unavailable.")
    }

    @Test func outputLargerThanPipeCapacityFinishesNormally() async throws {
        let url = try fixture("/usr/bin/awk 'BEGIN {for(i=0;i<20000;i++) print \"output data\"; print \"last line\"}'")
        defer { try? FileManager.default.removeItem(at: url) }
        let command = MakeCommand(resources: url, timeout: .seconds(2))
        let result = await command.run("status")
        #expect(result.exitCode == 0)
        #expect(result.output.hasSuffix("last line\n"))
        #expect(result.output.utf8.count <= 65536)
    }

    @Test func rejectsConcurrentAndUnknownCommandsAndAcceptsNextRun() async throws {
        let url = try fixture("sleep 0.2; printf 'complete\\n'")
        defer { try? FileManager.default.removeItem(at: url) }
        let command = MakeCommand(resources: url, timeout: .seconds(2))
        let first = Task { await command.run("status") }
        try await Task.sleep(for: .milliseconds(30))
        let concurrent = await command.run("stop")
        #expect(concurrent.exitCode == 1)
        #expect(concurrent.output == "Control command unavailable.")
        let result = await first.value
        #expect(result.exitCode == 0)
        #expect(result.output == "complete\n")
        let invalid = await command.run("arbitrary-shell-target")
        #expect(invalid.exitCode == 1)
        #expect(invalid.output == "Control command unavailable.")
        let second = await command.run("status")
        #expect(second.exitCode == 0)
    }

    @Test func timedOutCallbackCannotClearAnotherRun() async throws {
        let url = try fixture("trap '' TERM; sleep 0.25")
        defer { try? FileManager.default.removeItem(at: url) }
        let command = MakeCommand(resources: url, timeout: .milliseconds(100))
        let first = await command.run("status")
        #expect(first.exitCode == 124)
        let next = Task { await command.run("status") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await command.run("start").exitCode == 1)
        #expect(await next.value.exitCode == 124)
    }
}
