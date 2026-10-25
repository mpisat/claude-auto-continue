import Foundation
import Testing
@testable import ResumeCore

@MainActor struct LocalFilesTests {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func session(_ root: URL) -> Session {
        Session(id: "local_1", cliSessionID: "cli1", cwd: "/tmp/test", title: "Title", transcriptURL: root.appendingPathComponent("cli1.jsonl"))
    }
    let limit = #"{"type":"assistant","uuid":"limit-1","error":"rate_limit","apiErrorParams":{"rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":100}},"message":{"role":"assistant","model":"<synthetic>","content":[]}}"#
    @Test func readsLatestFiveHourErrorAndIgnoresOnlyNonSubstantiveRows() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        let rows = [limit,
            #"{"type":"assistant","uuid":"side","isSidechain":true,"message":{"content":[]}}"#,
            #"{"type":"user","uuid":"tool","message":{"content":[{"type":"tool_result","content":"result"}]}}"#,
            #"{"type":"user","uuid":"task","origin":{"kind":"task-notification"},"message":{"content":"notification"}}"#,
            #"{"type":"system","uuid":"system"}"#]
        try (rows.joined(separator: "\n") + "\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
        #expect(try FileTranscriptSource().latest(value) == .limited(LimitEvent(fingerprint: "limit-1", resetsAt: Date(timeIntervalSince1970: 100))))
    }
    @Test func nativeSessionMetadataDoesNotHideTheLatestLimit() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        let rows = [
            #"{"type":"custom-title","customTitle":"Title","sessionId":"cli1"}"#,
            #"{"type":"agent-name","agentName":"Agent","sessionId":"cli1"}"#,
            #"{"type":"last-prompt","lastPrompt":"Prompt","leafUuid":"leaf","sessionId":"cli1"}"#,
            #"{"type":"cost-state","sessionId":"cli1","totalCostUSD":1}"#,
            #"{"type":"mode","mode":"auto","sessionId":"cli1"}"#,
            #"{"type":"isolation-latch","side":"local","sessionId":"cli1"}"#,
            #"{"type":"atis-latch","atis":"value","sessionId":"cli1"}"#
        ]
        try ([limit] + rows).joined(separator: "\n").appending("\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
        let result = try FileTranscriptSource().latest(value)
        #expect(result == .limited(LimitEvent(fingerprint: "limit-1", resetsAt: Date(timeIntervalSince1970: 100))))
    }
    @Test func relocatedMetadataPreservesLatestNormalAssistantEvidence() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        let assistant = #"{"type":"assistant","uuid":"normal-output","message":{"model":"claude-opus","content":[{"type":"text","text":"Done"}]}}"#
        let relocated = #"{"type":"relocated","relocatedCwd":"/tmp/relocated","sessionId":"cli1"}"#
        try (assistant + "\n" + relocated + "\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
        let result = try FileTranscriptSource().latest(value)
        #expect(result == .assistant("normal-output"))
    }
    @Test func unknownMetadataShapeAndMessagesAreNotSilentlySkipped() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        for row in [#"{"type":"future-metadata","sessionId":"cli1"}"#,
                    #"{"type":"custom-title","sessionId":"cli1"}"#,
                    #"{"type":"custom-title","customTitle":"Title","sessionId":"cli1","message":{"content":"request"}}"#] {
            try (limit + "\n" + row + "\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
            let result = try FileTranscriptSource().latest(value)
            #expect(result == .unavailable)
        }
    }
    @Test func newerHumanSystemReminderAndAutomaticContinuationSuppressLimit() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        for origin in ["human", "auto-continuation"] {
            let row = "{\"type\":\"user\",\"uuid\":\"new-user\",\"origin\":{\"kind\":\"\(origin)\"},\"message\":{\"content\":\"<system-reminder> wrapped human text\"}}"
            try (limit + "\n" + row + "\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
            #expect(try FileTranscriptSource().latest(value) == .human("new-user"))
        }
    }
    @Test func weeklyAcceptedMissingResetAndMissingFingerprintNeverQualify() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        let rows = [limit.replacingOccurrences(of: "five_hour", with: "seven_day"),
                    limit.replacingOccurrences(of: "rejected", with: "allowed"),
                    limit.replacingOccurrences(of: ",\"resetsAt\":100", with: ""),
                    limit.replacingOccurrences(of: "\"uuid\":\"limit-1\",", with: "")]
        for row in rows {
            try (row + "\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
            #expect(try FileTranscriptSource().latest(value) == .unavailable)
        }
    }
    @Test func quotaLimitsFallbackIsAccepted() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        let row = #"{"type":"assistant","uuid":"fallback","error":"rate_limit","quotaLimits":{"status":"rejected","rateLimitType":"five_hour","resetsAt":100}}"#
        try (row + "\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
        #expect(try FileTranscriptSource().latest(value) == .limited(LimitEvent(fingerprint: "fallback", resetsAt: Date(timeIntervalSince1970: 100))))
    }
    @Test func normalModelOutputSuppressesLimitButSyntheticIsNotProofOfProgress() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        for model in ["claude-opus", "<synthetic>"] {
            let row = "{\"type\":\"assistant\",\"uuid\":\"new-output\",\"message\":{\"model\":\"\(model)\",\"content\":[{\"type\":\"tool_use\"}]}}"
            try (limit + "\n" + row + "\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
            let expected: TranscriptSnapshot = model == "<synthetic>" ? .unavailable : .assistant("new-output")
            #expect(try FileTranscriptSource().latest(value) == expected)
        }
    }
    @Test func assistantApiFailureWithoutErrorFieldIsNotVerifiedProgress() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        let row = #"{"type":"assistant","uuid":"failed","apiError":"unknown_error","message":{"model":"claude-opus","content":[{"type":"text","text":"Failure"}]}}"#
        try (row + "\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
        let result = try FileTranscriptSource().latest(value)
        #expect(result == .unavailable)
    }
    @Test func malformedAndPartialTailFailClosedInsteadOfReusingStaleLimit() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        for tail in ["{malformed}\n", "{\"type\":\"user\""] {
            try (limit + "\n" + tail).write(to: value.transcriptURL, atomically: true, encoding: .utf8)
            #expect(try FileTranscriptSource().latest(value) == .unavailable)
        }
    }
    @Test func callerScanBudgetBoundsMetadataOnlyTail() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        let metadata = #"{"type":"system","uuid":"metadata"}"# + "\n"
        try (limit + "\n" + String(repeating: metadata, count: 5000)).write(to: value.transcriptURL, atomically: true, encoding: .utf8)
        let reader = FileTranscriptSource(maxScanBytes: 65536)
        let result = try reader.latest(value)
        #expect(result == .unavailable)
        #expect(reader.bytesRead <= 65536)
    }
    @Test func scansTailWithoutLoadingHistoryAndCachesUnchangedFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(root)
        try (String(repeating: "x", count: 2_000_000) + "\n" + limit + "\n").write(to: value.transcriptURL, atomically: true, encoding: .utf8)
        let reader = FileTranscriptSource()
        #expect(try reader.latest(value) == .limited(LimitEvent(fingerprint: "limit-1", resetsAt: Date(timeIntervalSince1970: 100))))
        #expect(reader.bytesRead <= 65536)
        let read = reader.bytesRead
        _ = try reader.latest(value)
        #expect(reader.bytesRead == read)
    }
    @Test func discoversOnlyUnarchivedLocalSessionsWithMatchingTranscripts() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("metadata/account/org"), projects = root.appendingPathComponent("projects/escaped")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try "".write(to: projects.appendingPathComponent("cli1.jsonl"), atomically: true, encoding: .utf8)
        for (id, archived, cli) in [("local_1", false, "cli1"), ("local_archived", true, "cli1"), ("remote_1", false, "cli1"), ("local_missing", false, "missing")] {
            let object: [String: Any] = ["sessionId": id, "cliSessionId": cli, "cwd": "/tmp/test", "title": "Title", "isArchived": archived]
            try JSONSerialization.data(withJSONObject: object).write(to: metadata.appendingPathComponent(id + ".json"))
        }
        let source = FileSessionSource(metadataRoot: root.appendingPathComponent("metadata"), projectsRoot: root.appendingPathComponent("projects"))
        let discovered = try source.discover()
        #expect(discovered.count == 1)
        #expect(discovered.first?.id == "local_1")
        #expect(discovered.first?.cliSessionID == "cli1")
        #expect(discovered.first?.transcriptURL.resolvingSymlinksInPath() == projects.appendingPathComponent("cli1.jsonl").resolvingSymlinksInPath())
    }
    @Test func discoveryRefreshesMovedTranscriptWithoutRestart() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("metadata/account/org")
        let projects = root.appendingPathComponent("projects")
        let original = projects.appendingPathComponent("old/cli1.jsonl")
        let relocated = projects.appendingPathComponent("new/cli1.jsonl")
        for directory in [metadata, original.deletingLastPathComponent(), relocated.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let object: [String: Any] = ["sessionId": "local_1", "cliSessionId": "cli1", "cwd": "/tmp/test", "title": "Title", "isArchived": false]
        try JSONSerialization.data(withJSONObject: object).write(to: metadata.appendingPathComponent("local_1.json"))
        try "".write(to: original, atomically: true, encoding: .utf8)
        let source = FileSessionSource(metadataRoot: root.appendingPathComponent("metadata"), projectsRoot: projects)
        let first = try source.discover()
        #expect(first.count == 1)
        #expect(first.first?.transcriptURL.resolvingSymlinksInPath() == original.resolvingSymlinksInPath())
        try FileManager.default.moveItem(at: original, to: relocated)
        let second = try source.discover()
        #expect(second.count == 1)
        #expect(second.first?.transcriptURL.resolvingSymlinksInPath() == relocated.resolvingSymlinksInPath())
    }
    @Test(arguments: [false, true]) func discoveryRejectsNewDuplicateWithoutRestart(newDirectory: Bool) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("metadata/account/org")
        let projects = root.appendingPathComponent("projects")
        let original = projects.appendingPathComponent("old/cli1.jsonl")
        let duplicate = projects.appendingPathComponent("duplicate/cli1.jsonl")
        for directory in [metadata, original.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if !newDirectory { try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let object: [String: Any] = ["sessionId": "local_1", "cliSessionId": "cli1", "cwd": "/tmp/test", "title": "Title", "isArchived": false]
        try JSONSerialization.data(withJSONObject: object).write(to: metadata.appendingPathComponent("local_1.json"))
        try "".write(to: original, atomically: true, encoding: .utf8)
        let source = FileSessionSource(metadataRoot: root.appendingPathComponent("metadata"), projectsRoot: projects)
        #expect(try source.discover().count == 1)
        if newDirectory { try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try "".write(to: duplicate, atomically: true, encoding: .utf8)
        let afterDuplicate = try source.discover()
        #expect(afterDuplicate.isEmpty)
    }
    @Test func atomicStoreRoundTripsAndCorruptionFailsClosed() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state/state.json"), store = AtomicStateStore(url: root.appendingPathComponent("state/state.json"))
        #expect(try store.load() == ResumeState())
        let state = ResumeState(attempts: ["key": Attempt(fingerprint: "event", count: 1, status: .pending, nextAttemptAt: Date(timeIntervalSince1970: 100))])
        try store.save(state)
        #expect(try store.load() == state)
        try "broken".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try store.load() }
    }
}
