import Foundation

public struct Session: Equatable, Sendable {
    public let id: String
    public let cliSessionID: String
    public let cwd: String
    public let title: String
    public let transcriptURL: URL

    public init(id: String, cliSessionID: String, cwd: String, title: String, transcriptURL: URL) {
        self.id = id
        self.cliSessionID = cliSessionID
        self.cwd = cwd
        self.title = title
        self.transcriptURL = transcriptURL
    }
}

public struct LimitEvent: Equatable, Sendable {
    public let fingerprint: String
    public let resetsAt: Date
    public init(fingerprint: String, resetsAt: Date) {
        self.fingerprint = fingerprint
        self.resetsAt = resetsAt
    }
}

public enum TranscriptSnapshot: Equatable, Sendable {
    case limited(LimitEvent)
    case assistant(String)
    case human(String)
    case unavailable
}

public enum Readiness: String, Codable, Sendable {
    case ready, busy, draft, notLimited, wrongIdentity, unavailable
}

public enum PressOutcome: String, Codable, Sendable {
    case pressed, definitelyNotSent, ambiguous
}

@MainActor public protocol ResumeUI: AnyObject {
    func prepare(_ session: Session) async -> Readiness
    func pressRetry(_ session: Session, expected: LimitEvent) async -> PressOutcome
}
@MainActor public protocol SessionSource: AnyObject { func discover() throws -> [Session] }
@MainActor public protocol TranscriptSource: AnyObject { func latest(_ session: Session) throws -> TranscriptSnapshot }
@MainActor public protocol StateStore: AnyObject {
    func load() throws -> ResumeState
    func save(_ state: ResumeState) throws
}

public struct Attempt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, notSent, confirmed }
    public var fingerprint: String
    public var count: Int
    public var status: Status
    public var nextAttemptAt: Date
}
public struct ResumeState: Codable, Equatable, Sendable {
    public var attempts: [String: Attempt]
    public init(attempts: [String: Attempt] = [:]) { self.attempts = attempts }
}
public struct SessionResult: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case waiting, ineligible, blocked(Readiness), dryRun, attempted(PressOutcome)
        case alreadyAttempted, backoff, attemptsExhausted, progressVerified, failed
    }
    public let sessionID: String
    public let outcome: Outcome
    public init(sessionID: String, outcome: Outcome) { self.sessionID = sessionID; self.outcome = outcome }
}

@MainActor public final class ResumeCoordinator {
    private let sessions: any SessionSource
    private let transcripts: any TranscriptSource
    private let state: any StateStore
    private let ui: any ResumeUI
    private let now: () -> Date
    private let nativeGrace: TimeInterval
    private var running = false
    public init(sessions: any SessionSource, transcripts: any TranscriptSource, state: any StateStore,
                ui: any ResumeUI, nativeGrace: TimeInterval = 0, now: @escaping () -> Date = Date.init) {
        self.sessions = sessions; self.transcripts = transcripts; self.state = state; self.ui = ui; self.now = now
        self.nativeGrace = nativeGrace
    }
    public func runOnce(dryRun: Bool = false) async -> [SessionResult] {
        guard !running else { return [] }
        running = true
        defer { running = false }
        let discovered: [Session]
        var saved: ResumeState
        do {
            discovered = try sessions.discover()
            saved = try state.load()
        } catch { return [SessionResult(sessionID: "", outcome: .failed)] }
        var results: [SessionResult] = []
        for session in discovered {
            do {
                let outcome = try await process(session, saved: &saved, dryRun: dryRun)
                results.append(SessionResult(sessionID: session.id, outcome: outcome))
            } catch { results.append(SessionResult(sessionID: session.id, outcome: .failed)) }
        }
        return results
    }

    private func process(_ session: Session, saved: inout ResumeState, dryRun: Bool) async throws -> SessionResult.Outcome {
        let snapshot = try transcripts.latest(session)
        let prefix = session.id + ":"
        if case .assistant = snapshot {
            let pending = saved.attempts.keys.filter { $0.hasPrefix(prefix) && saved.attempts[$0]?.status == .pending }
            guard !pending.isEmpty else { return .ineligible }
            if !dryRun {
                var changed = saved
                for key in pending { changed.attempts[key]?.status = .confirmed }
                try state.save(changed)
                saved = changed
            }
            return .progressVerified
        }
        guard case let .limited(event) = snapshot else { return .ineligible }
        guard event.resetsAt.addingTimeInterval(nativeGrace) <= now() else { return .waiting }
        let key = prefix + String(event.resetsAt.timeIntervalSince1970)
        if let previous = saved.attempts[key] {
            // A new structured rejection proves the previous action returned from the API.
            // The same event remains uncertain and is never replayed after a possible send.
            guard previous.status == .notSent || previous.fingerprint != event.fingerprint else { return .alreadyAttempted }
            guard previous.count < 3 else { return .attemptsExhausted }
            guard previous.nextAttemptAt <= now() else { return .backoff }
        }
        if dryRun { return .dryRun }
        let readiness = await ui.prepare(session)
        guard readiness == .ready else { return .blocked(readiness) }
        guard try sessions.discover().contains(session) else { return .ineligible }
        // Navigation can race Desktop's own continuation. Read again after that suspension.
        guard try transcripts.latest(session) == .limited(event), event.resetsAt <= now() else { return .ineligible }
        let count = (saved.attempts[key]?.count ?? 0) + 1
        var intent = saved
        intent.attempts[key] = Attempt(fingerprint: event.fingerprint, count: count, status: .pending, nextAttemptAt: now().addingTimeInterval(30 * Double(count)))
        // Persist an uncertain send before the action: a crash must never replay it.
        try state.save(intent)
        saved = intent
        guard try transcripts.latest(session) == .limited(event) else { return .ineligible }
        let result = await ui.pressRetry(session, expected: event)
        if result == .definitelyNotSent {
            var unsent = saved
            unsent.attempts[key]?.status = .notSent
            unsent.attempts[key]?.nextAttemptAt = now().addingTimeInterval(30 * Double(count))
            try state.save(unsent)
            saved = unsent
        }
        return .attempted(result)
    }
}
