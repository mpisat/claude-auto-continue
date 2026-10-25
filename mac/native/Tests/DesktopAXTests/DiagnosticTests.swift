import XCTest
import ResumeCore
@testable import DesktopAX

@MainActor final class DiagnosticReviewTests: XCTestCase {
    enum ReadFailure: Error { case denied }
    final class Transcript: TranscriptSource {
        func latest(_ session: Session) throws -> TranscriptSnapshot { throw ReadFailure.denied }
    }
    func testActionFailureReplacesPreparationDiagnostic() async {
        let id = "local_12345678-1234-1234-1234-123456789abc"
        let session = Session(id: id, cliSessionID: "cli", cwd: "/tmp/repo", title: "Task", transcriptURL: URL(fileURLWithPath: "/tmp/unused.jsonl"))
        let page = Node(role: "AXWebArea", url: "https://claude.ai/epitaxy/" + id, children: [
            Node(label: "Primary pane", children: [
                Node(role: "AXTextArea", label: "Prompt"),
                Node(children: [Node(role: "AXStaticText", value: "Session limit reached"), Node(id: 9, role: "AXButton", label: "Try again")])
            ])
        ])
        let desktop = Desktop(transcripts: Transcript(), foreground: { false }, snapshot: { page })
        let prepared = await desktop.prepare(session)
        XCTAssertEqual(prepared, .ready)
        let result = await desktop.pressRetry(session, expected: LimitEvent(fingerprint: "limit", resetsAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(result, .definitelyNotSent)
        XCTAssertEqual(desktop.lastDiagnostic, "denied")
        XCTAssertEqual(desktop.diagnostic(for: id), "denied")
    }
    final class ChangedTranscript: TranscriptSource {
        func latest(_ session: Session) throws -> TranscriptSnapshot { .human("new-human-input") }
    }
    func testActionVetoExplainsChangedTranscriptInsteadOfReady() async {
        let id = "local_12345678-1234-1234-1234-123456789abc"
        let session = Session(id: id, cliSessionID: "cli", cwd: "/tmp/repo", title: "Task", transcriptURL: URL(fileURLWithPath: "/tmp/unused.jsonl"))
        let desktop = Desktop(transcripts: ChangedTranscript(), navigation: { _ in .ready }, foreground: { false })
        let prepared = await desktop.prepare(session)
        XCTAssertEqual(prepared, .ready)
        let result = await desktop.pressRetry(session, expected: LimitEvent(fingerprint: "limit", resetsAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(result, .definitelyNotSent)
        XCTAssertEqual(desktop.diagnostic(for: id), "Retry skipped: transcript changed or reset is still in the future")
    }

}
