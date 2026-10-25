import Foundation
import Testing
@testable import ResumeCore

@MainActor struct ProductionBoundaryTests {
    @Test func nativeGraceWaitsUntilResetPlus120WithoutChangingEventIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cli.jsonl")
        try (LocalFilesTests().limit + "\n").write(to: url, atomically: true, encoding: .utf8)
        let sessions = Sessions(), transcripts = FileTranscriptSource(), state = Store(), ui = UI()
        sessions.values = [Session(id: "local_0", cliSessionID: "cli", cwd: "/tmp/test", title: "Title", transcriptURL: url)]
        var now = Date(timeIntervalSince1970: 219)
        let core = ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: state, ui: ui, nativeGrace: 120, now: { now })
        let beforeGrace = await core.runOnce()
        #expect(beforeGrace.map(\.outcome) == [.waiting])
        #expect(ui.presses.isEmpty)
        #expect(state.writes == 0)
        now = Date(timeIntervalSince1970: 220)
        let afterGrace = await core.runOnce()
        #expect(afterGrace.map(\.outcome) == [.attempted(.pressed)])
        #expect(ui.presses == ["local_0"])
        #expect(state.value.attempts.keys.sorted() == ["local_0:100.0"])
        #expect(state.value.attempts["local_0:100.0"]?.fingerprint == "limit-1")
    }
    @Test func duplicateCreatedDuringNavigationBlocksTheAction() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("account/org"), projects = root.appendingPathComponent("projects")
        let original = projects.appendingPathComponent("original/cli.jsonl"), duplicate = projects.appendingPathComponent("duplicate/cli.jsonl")
        for directory in [metadata, original.deletingLastPathComponent(), duplicate.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let object: [String: Any] = ["sessionId": "local_0", "cliSessionId": "cli", "cwd": "/tmp/test", "title": "Title", "isArchived": false]
        try JSONSerialization.data(withJSONObject: object).write(to: metadata.appendingPathComponent("local_0.json"))
        try (LocalFilesTests().limit + "\n").write(to: original, atomically: true, encoding: .utf8)
        let source = FileSessionSource(metadataRoot: root.appendingPathComponent("account"), projectsRoot: projects)
        let ui = UI(), store = Store()
        ui.onPrepare = { _ in
            do { try FileManager.default.copyItem(at: original, to: duplicate) }
            catch { Issue.record("Could not create duplicate fixture: \(error)") }
        }
        let results = await ResumeCoordinator(sessions: source, transcripts: FileTranscriptSource(), state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) }).runOnce()
        #expect(results.map(\.outcome) == [.ineligible])
        #expect(ui.presses.isEmpty)
        #expect(store.writes == 0)
    }
    @Test func localDiscoveryAndTranscriptPolicyThroughCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("account/org"), projects = root.appendingPathComponent("projects/cwd")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let limit = LocalFilesTests().limit
        let suffixes = ["", "", "", "", "", "", "\n" + #"{"type":"user","uuid":"human","origin":{"kind":"human"},"message":{"content":"new request"}}"#,
                        "\n" + #"{"type":"assistant","uuid":"finished","message":{"model":"claude-opus","content":[{"type":"text","text":"Done"}]}}"#]
        for index in 0..<suffixes.count {
            let cli = "cli\(index)", id = "local_\(index)"
            let object: [String: Any] = ["sessionId": id, "cliSessionId": cli, "cwd": "/tmp/test", "title": "Title", "isArchived": false]
            try JSONSerialization.data(withJSONObject: object).write(to: metadata.appendingPathComponent(id + ".json"))
            let row = index == 5 ? limit.replacingOccurrences(of: "five_hour", with: "seven_day") : limit
            let nativeMetadata = "\n{\"type\":\"cost-state\",\"sessionId\":\"\(cli)\",\"totalCostUSD\":1}\n"
            try (row + suffixes[index] + nativeMetadata).write(to: projects.appendingPathComponent(cli + ".jsonl"), atomically: true, encoding: .utf8)
        }
        let ui = UI(), state = AtomicStateStore(url: root.appendingPathComponent("state.json"))
        let source = FileSessionSource(metadataRoot: root.appendingPathComponent("account"), projectsRoot: root.appendingPathComponent("projects"))
        let make = { ResumeCoordinator(sessions: source, transcripts: FileTranscriptSource(), state: state, ui: ui, now: { Date(timeIntervalSince1970: 200) }) }
        let first = await make().runOnce()
        #expect(first.map(\.outcome) == [.attempted(.pressed), .attempted(.pressed), .attempted(.pressed), .attempted(.pressed), .attempted(.pressed), .ineligible, .ineligible, .ineligible])
        #expect(ui.presses == ["local_0", "local_1", "local_2", "local_3", "local_4"])
        let restarted = await make().runOnce()
        #expect(restarted.prefix(5).allSatisfy { $0.outcome == .alreadyAttempted })
        #expect(ui.presses.count == 5)
    }
}
