import Foundation
import Testing
@testable import ResumeCore

@MainActor final class Sessions: SessionSource {
    var values: [Session]
    init(_ count: Int = 1) { values = (0..<count).map { Session(id: "local_\($0)", cliSessionID: "cli\($0)", cwd: "/tmp/project", title: "Session \($0)", transcriptURL: URL(fileURLWithPath: "/tmp/\($0).jsonl")) } }
    func discover() throws -> [Session] { values }
}
@MainActor final class Transcripts: TranscriptSource {
    var values: [String: TranscriptSnapshot] = [:]
    var errorIDs: Set<String> = []
    func latest(_ session: Session) throws -> TranscriptSnapshot {
        if errorIDs.contains(session.id) { throw CocoaError(.fileReadUnknown) }
        return values[session.id] ?? .limited(LimitEvent(fingerprint: "error-\(session.id)", resetsAt: Date(timeIntervalSince1970: 100)))
    }
}
@MainActor final class Store: StateStore {
    var value = ResumeState()
    var writes = 0
    var failSave = false
    var onSave: ((ResumeState) -> Void)?
    func load() throws -> ResumeState { value }
    func save(_ state: ResumeState) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        value = state; writes += 1; onSave?(state)
    }
}
@MainActor final class UI: ResumeUI {
    var readiness: [String: Readiness] = [:]
    var presses: [String] = []
    var expectedEvents: [LimitEvent] = []
    var outcome = PressOutcome.pressed
    var onPrepare: ((Session) -> Void)?
    var beforePress: (() -> Void)?
    var onPrepareAsync: (() async -> Void)?
    func prepare(_ session: Session) async -> Readiness { onPrepare?(session); await onPrepareAsync?(); return readiness[session.id] ?? .ready }
    func pressRetry(_ session: Session, expected: LimitEvent) async -> PressOutcome { beforePress?(); expectedEvents.append(expected); presses.append(session.id); return outcome }
}
@MainActor struct CoordinatorTests {
    @Test func transcriptChangeDuringIntentPersistencePreventsPressingADifferentEvent() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        store.onSave = { _ in
            transcripts.values["local_0"] = .limited(LimitEvent(fingerprint: "event-b", resetsAt: Date(timeIntervalSince1970: 100)))
        }
        let core = ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) })
        let result = await core.runOnce()
        #expect(result.map(\.outcome) == [.ineligible])
        #expect(ui.presses.isEmpty)
        #expect(store.value.attempts["local_0:100.0"]?.fingerprint == "error-local_0")
        #expect(store.value.attempts["local_0:100.0"]?.status == .pending)
    }
    @Test func overlappingRunsCannotReplayTheSameIntent() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        let core = ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) })
        ui.onPrepareAsync = {
            ui.onPrepareAsync = nil
            _ = await core.runOnce()
        }
        _ = await core.runOnce()
        #expect(ui.presses.count == 1)
    }
    @Test func automaticContinuationDuringNavigationCancelsOwnRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = Sessions(), transcripts = FileTranscriptSource(), store = Store(), ui = UI()
        let url = root.appendingPathComponent("cli.jsonl")
        sessions.values = [Session(id: "local_0", cliSessionID: "cli", cwd: "/tmp/test", title: "Title", transcriptURL: url)]
        let limit = LocalFilesTests().limit + "\n"
        try limit.write(to: url, atomically: true, encoding: .utf8)
        ui.onPrepare = { _ in
            let continuation = #"{"type":"user","uuid":"native-continuation","origin":{"kind":"auto-continuation"},"message":{"content":"Continue."}}"#
            try? (limit + continuation + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let result = await ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) }).runOnce()
        #expect(result.map(\.outcome) == [.ineligible])
        #expect(ui.presses.isEmpty)
        #expect(store.writes == 0)
    }
    @Test func fiveIndependentSessionsAreRetriedAndIntentsAreDurableBeforePress() async {
        let sessions = Sessions(5), transcripts = Transcripts(), store = Store(), ui = UI()
        ui.beforePress = { #expect(store.value.attempts.values.contains { $0.status == .pending }) }
        let core = ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) })
        let results = await core.runOnce()
        #expect(results.count == 5)
        #expect(ui.presses == sessions.values.map(\.id))
        #expect(ui.expectedEvents.map(\.fingerprint) == sessions.values.map { "error-\($0.id)" })
        #expect(results.allSatisfy { $0.outcome == .attempted(.pressed) })
        #expect(store.writes == 5)
    }
    @Test func futureResetAndCompletedAndManualInputAreNotRetried() async {
        let sessions = Sessions(3), transcripts = Transcripts(), store = Store(), ui = UI()
        transcripts.values["local_0"] = .limited(LimitEvent(fingerprint: "future", resetsAt: Date(timeIntervalSince1970: 300)))
        transcripts.values["local_1"] = .assistant("completed")
        transcripts.values["local_2"] = .human("manual")
        let results = await ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) }).runOnce()
        #expect(results.map(\.outcome) == [.waiting, .ineligible, .ineligible])
        #expect(ui.presses.isEmpty)
        #expect(store.writes == 0)
    }
    @Test func draftWrongIdentityAndBusyBlockWithoutWrites() async {
        let sessions = Sessions(3), transcripts = Transcripts(), store = Store(), ui = UI()
        ui.readiness = ["local_0": .draft, "local_1": .wrongIdentity, "local_2": .busy]
        let results = await ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) }).runOnce()
        #expect(results.map(\.outcome) == [.blocked(.draft), .blocked(.wrongIdentity), .blocked(.busy)])
        #expect(ui.presses.isEmpty)
        #expect(store.writes == 0)
    }
    @Test func nativeResumeDuringNavigationCancelsPress() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        ui.onPrepare = { transcripts.values[$0.id] = .assistant("native-progress") }
        let results = await ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) }).runOnce()
        #expect(results.map(\.outcome) == [.ineligible])
        #expect(ui.presses.isEmpty)
    }
    @Test func unconfirmedPressIsNotRepeatedAcrossRestartAndNewErrorIsNotProgress() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        let make = { ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) }) }
        _ = await make().runOnce()
        transcripts.values["local_0"] = .limited(LimitEvent(fingerprint: "another-429", resetsAt: Date(timeIntervalSince1970: 100)))
        let second = await make().runOnce()
        #expect(ui.presses.count == 1)
        #expect(second.map(\.outcome) == [.backoff])
        transcripts.values["local_0"] = .assistant("normal-progress")
        let third = await make().runOnce()
        #expect(third.map(\.outcome) == [.progressVerified])
    }
    @Test func newRejectionRearmsWithBackoffButSameFingerprintNeverReplays() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        var now = Date(timeIntervalSince1970: 200)
        let make = { ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { now }) }
        _ = await make().runOnce()
        now = Date(timeIntervalSince1970: 300)
        #expect(await make().runOnce().map(\.outcome) == [.alreadyAttempted])
        transcripts.values["local_0"] = .limited(LimitEvent(fingerprint: "rejected-2", resetsAt: Date(timeIntervalSince1970: 100)))
        #expect(await make().runOnce().map(\.outcome) == [.attempted(.pressed)])
        transcripts.values["local_0"] = .limited(LimitEvent(fingerprint: "rejected-3", resetsAt: Date(timeIntervalSince1970: 100)))
        #expect(await make().runOnce().map(\.outcome) == [.backoff])
        now = Date(timeIntervalSince1970: 400)
        _ = await make().runOnce()
        transcripts.values["local_0"] = .limited(LimitEvent(fingerprint: "rejected-4", resetsAt: Date(timeIntervalSince1970: 100)))
        now = Date(timeIntervalSince1970: 500)
        #expect(await make().runOnce().map(\.outcome) == [.attemptsExhausted])
        #expect(ui.presses.count == 3)
        transcripts.values["local_0"] = .limited(LimitEvent(fingerprint: "new-window", resetsAt: Date(timeIntervalSince1970: 450)))
        #expect(await make().runOnce().map(\.outcome) == [.attempted(.pressed)])
        #expect(ui.presses.count == 4)
    }
    @Test func confirmedProgressAllowsANewRejectionWithinTheSameResetCap() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        var now = Date(timeIntervalSince1970: 200)
        let make = { ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { now }) }
        for index in 1...3 {
            transcripts.values["local_0"] = .limited(LimitEvent(fingerprint: "error-\(index)", resetsAt: Date(timeIntervalSince1970: 100)))
            #expect(await make().runOnce().map(\.outcome) == [.attempted(.pressed)])
            transcripts.values["local_0"] = .assistant("progress-\(index)")
            #expect(await make().runOnce().map(\.outcome) == [.progressVerified])
            now = now.addingTimeInterval(100)
        }
        transcripts.values["local_0"] = .limited(LimitEvent(fingerprint: "fourth-rejection", resetsAt: Date(timeIntervalSince1970: 100)))
        #expect(await make().runOnce().map(\.outcome) == [.attemptsExhausted])
        #expect(ui.presses.count == 3)
    }
    @Test func ambiguousPressIsNotRepeated() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        ui.outcome = .ambiguous
        let core = ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) })
        _ = await core.runOnce(); _ = await core.runOnce()
        #expect(ui.presses.count == 1)
    }
    @Test func persistenceFailurePreventsSending() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        store.failSave = true
        let results = await ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) }).runOnce()
        #expect(results.map(\.outcome) == [.failed])
        #expect(ui.presses.isEmpty)
    }
    @Test func failureDoesNotStarveLaterSession() async {
        let sessions = Sessions(2), transcripts = Transcripts(), store = Store(), ui = UI()
        transcripts.errorIDs = ["local_0"]
        let results = await ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) }).runOnce()
        #expect(results.map(\.outcome) == [.failed, .attempted(.pressed)])
        #expect(ui.presses == ["local_1"])
    }
    @Test func definitelyUnsentRetriesUseBackoffAndThreeAttemptCap() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        ui.outcome = .definitelyNotSent
        var now = Date(timeIntervalSince1970: 200)
        let core = ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { now })
        _ = await core.runOnce()
        #expect(await core.runOnce().map(\.outcome) == [.backoff])
        now = Date(timeIntervalSince1970: 230); _ = await core.runOnce()
        now = Date(timeIntervalSince1970: 290); _ = await core.runOnce()
        now = Date(timeIntervalSince1970: 1000)
        #expect(await core.runOnce().map(\.outcome) == [.attemptsExhausted])
        #expect(ui.presses.count == 3)
    }
    @Test func dryRunDoesNotNavigateOrPersist() async {
        let sessions = Sessions(), transcripts = Transcripts(), store = Store(), ui = UI()
        ui.onPrepare = { _ in Issue.record("Dry run must not navigate") }
        let results = await ResumeCoordinator(sessions: sessions, transcripts: transcripts, state: store, ui: ui, now: { Date(timeIntervalSince1970: 200) }).runOnce(dryRun: true)
        #expect(results.map(\.outcome) == [.dryRun])
        #expect(ui.presses.isEmpty)
        #expect(store.writes == 0)
    }
}
