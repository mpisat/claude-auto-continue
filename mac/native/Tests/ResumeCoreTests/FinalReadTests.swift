import Foundation
import Testing
@testable import ResumeCore

@MainActor struct FinalReadTests {
    private let partialMetadata = #"{"type":"cost-state""#
    private let completedMetadata = #"{"type":"cost-state","sessionId":"cli1","totalCostUSD":1}"# + "\n"

    private func append(_ text: String, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data(text.utf8))
    }

    @Test func partialAppendAfterIntentCanRetryTheSameEventAfterBackoff() async throws {
        let fixtures = LocalFilesTests(), root = try fixtures.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = fixtures.session(root), sessions = Sessions(), store = Store(), ui = UI()
        sessions.values = [session]
        try (fixtures.limit + "\n").write(to: session.transcriptURL, atomically: true, encoding: .utf8)
        store.onSave = { _ in
            store.onSave = nil
            do { try append(partialMetadata, to: session.transcriptURL) }
            catch { Issue.record("Could not append partial metadata: \(error)") }
        }
        var now = Date(timeIntervalSince1970: 200)
        let make = { ResumeCoordinator(sessions: sessions, transcripts: FileTranscriptSource(), state: store, ui: ui, now: { now }) }
        #expect(await make().runOnce().map(\.outcome) == [.ineligible])
        #expect(try FileTranscriptSource().latest(session) == .unavailable)
        #expect(ui.presses.isEmpty)
        #expect(store.value.attempts["local_1:100.0"] == Attempt(fingerprint: "limit-1", count: 1, status: .notSent, nextAttemptAt: Date(timeIntervalSince1970: 230)))
        try append(",\"sessionId\":\"cli1\",\"totalCostUSD\":1}\n", to: session.transcriptURL)
        now = Date(timeIntervalSince1970: 229)
        #expect(await make().runOnce().map(\.outcome) == [.backoff])
        #expect(ui.presses.isEmpty)
        now = Date(timeIntervalSince1970: 230)
        ui.beforePress = {
            #expect(store.value.attempts["local_1:100.0"]?.status == .pending)
            #expect(store.value.attempts["local_1:100.0"]?.count == 2)
        }
        #expect(await make().runOnce().map(\.outcome) == [.attempted(.pressed)])
        #expect(ui.presses == ["local_1"])
        now = Date(timeIntervalSince1970: 1000)
        #expect(await make().runOnce().map(\.outcome) == [.alreadyAttempted])
        #expect(ui.presses == ["local_1"])
    }

    @Test func thrownFinalReadLeavesAnUnsentAttemptRetryable() async throws {
        let fixtures = LocalFilesTests(), root = try fixtures.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = fixtures.session(root), sessions = Sessions(), store = Store(), ui = UI()
        sessions.values = [session]
        let transcript = fixtures.limit + "\n"
        try transcript.write(to: session.transcriptURL, atomically: true, encoding: .utf8)
        store.onSave = { _ in
            store.onSave = nil
            do { try FileManager.default.removeItem(at: session.transcriptURL) }
            catch { Issue.record("Could not remove transcript fixture: \(error)") }
        }
        var now = Date(timeIntervalSince1970: 200)
        let make = { ResumeCoordinator(sessions: sessions, transcripts: FileTranscriptSource(), state: store, ui: ui, now: { now }) }
        #expect(await make().runOnce().map(\.outcome) == [.failed])
        do {
            _ = try FileTranscriptSource().latest(session)
            Issue.record("The removed transcript must fail to read")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadNoSuchFile)
        }
        #expect(ui.presses.isEmpty)
        #expect(store.value.attempts["local_1:100.0"] == Attempt(fingerprint: "limit-1", count: 1, status: .notSent, nextAttemptAt: Date(timeIntervalSince1970: 230)))
        try transcript.write(to: session.transcriptURL, atomically: true, encoding: .utf8)
        now = Date(timeIntervalSince1970: 229)
        #expect(await make().runOnce().map(\.outcome) == [.backoff])
        now = Date(timeIntervalSince1970: 230)
        #expect(await make().runOnce().map(\.outcome) == [.attempted(.pressed)])
        #expect(ui.presses == ["local_1"])
    }

    @Test(arguments: [false, true]) func failedUnsentPersistencePreservesPendingFence(missingFile: Bool) async throws {
        let fixtures = LocalFilesTests(), root = try fixtures.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = fixtures.session(root), sessions = Sessions(), store = Store(), ui = UI()
        sessions.values = [session]
        let transcript = fixtures.limit + "\n"
        try transcript.write(to: session.transcriptURL, atomically: true, encoding: .utf8)
        store.onSave = { _ in
            store.onSave = nil
            store.failSave = true
            do {
                if missingFile { try FileManager.default.removeItem(at: session.transcriptURL) }
                else { try append(partialMetadata, to: session.transcriptURL) }
            } catch { Issue.record("Could not change transcript fixture: \(error)") }
        }
        var now = Date(timeIntervalSince1970: 200)
        let make = { ResumeCoordinator(sessions: sessions, transcripts: FileTranscriptSource(), state: store, ui: ui, now: { now }) }
        #expect(await make().runOnce().map(\.outcome) == [.failed])
        #expect(ui.presses.isEmpty)
        #expect(store.writes == 1)
        #expect(store.value.attempts["local_1:100.0"]?.status == .pending)
        store.failSave = false
        try transcript.write(to: session.transcriptURL, atomically: true, encoding: .utf8)
        now = Date(timeIntervalSince1970: 1000)
        #expect(await make().runOnce().map(\.outcome) == [.alreadyAttempted])
        #expect(ui.presses.isEmpty)
    }

    @Test func finalReadVetoesRetainTheThreeAttemptCap() async throws {
        let fixtures = LocalFilesTests(), root = try fixtures.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = fixtures.session(root), sessions = Sessions(), store = Store(), ui = UI()
        sessions.values = [session]
        let transcript = fixtures.limit + "\n"
        try transcript.write(to: session.transcriptURL, atomically: true, encoding: .utf8)
        store.onSave = { state in
            guard state.attempts["local_1:100.0"]?.status == .pending else { return }
            do { try append(partialMetadata, to: session.transcriptURL) }
            catch { Issue.record("Could not append partial metadata: \(error)") }
        }
        var now = Date(timeIntervalSince1970: 200)
        let make = { ResumeCoordinator(sessions: sessions, transcripts: FileTranscriptSource(), state: store, ui: ui, now: { now }) }
        for count in 1...3 {
            #expect(await make().runOnce().map(\.outcome) == [.ineligible])
            #expect(ui.presses.isEmpty)
            #expect(store.value.attempts["local_1:100.0"]?.status == .notSent)
            #expect(store.value.attempts["local_1:100.0"]?.count == count)
            try (transcript + completedMetadata).write(to: session.transcriptURL, atomically: true, encoding: .utf8)
            now = now.addingTimeInterval(30 * Double(count))
        }
        #expect(await make().runOnce().map(\.outcome) == [.attemptsExhausted])
        #expect(ui.presses.isEmpty)
        #expect(store.value.attempts["local_1:100.0"]?.count == 3)
    }
}
