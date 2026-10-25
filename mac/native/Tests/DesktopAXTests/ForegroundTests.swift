import XCTest
import ResumeCore
@testable import DesktopAX

@MainActor final class ForegroundTests: XCTestCase {
    final class Transcript: TranscriptSource {
        func latest(_ session: Session) throws -> TranscriptSnapshot { .unavailable }
    }
    let session = Session(id: "local_12345678-1234-1234-1234-123456789abc", cliSessionID: "cli", cwd: "/tmp/repo", title: "Task", transcriptURL: URL(fileURLWithPath: "/tmp/unused.jsonl"))

    func testFailedBackgroundSelectionUsesOneForegroundFallback() async {
        for failure in [Readiness.wrongIdentity, .unavailable] {
            var calls: [String] = []
            var navigationCount = 0
            let desktop = Desktop(transcripts: Transcript(), navigation: { _ in
                calls.append("navigate"); navigationCount += 1
                return navigationCount == 1 ? failure : .ready
            }, foreground: { calls.append("foreground"); return true })
            let result = await desktop.prepare(session)
            XCTAssertEqual(result, .ready)
            XCTAssertEqual(calls, ["navigate", "foreground", "navigate"])
            XCTAssertTrue(desktop.lastDiagnostic.contains("foreground"))
        }
    }

    func testNonNavigationStatesNeverStealFocus() async {
        for state in [Readiness.ready, .busy, .draft, .notLimited] {
            var activations = 0
            let desktop = Desktop(transcripts: Transcript(), navigation: { _ in state },
                                  foreground: { activations += 1; return true })
            let result = await desktop.prepare(session)
            XCTAssertEqual(result, state)
            XCTAssertEqual(activations, 0)
        }
    }

    func testFailedActivationCannotBecomeReady() async {
        var navigations = 0
        let desktop = Desktop(transcripts: Transcript(), navigation: { _ in navigations += 1; return .wrongIdentity }, foreground: { false })
        let result = await desktop.prepare(session)
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(navigations, 1)
    }

    func testForegroundResultStillHonorsBusyDraftAndIdentityGuards() async {
        for state in [Readiness.busy, .draft, .notLimited, .wrongIdentity, .unavailable] {
            var navigations = 0
            var activations = 0
            let desktop = Desktop(transcripts: Transcript(), navigation: { _ in
                navigations += 1; return navigations == 1 ? .wrongIdentity : state
            }, foreground: { activations += 1; return true })
            let result = await desktop.prepare(session)
            XCTAssertEqual(result, state)
            XCTAssertEqual(navigations, 2)
            XCTAssertEqual(activations, 1)
        }
    }
    func testUnknownCurrentIdentityStillPreservesTheDraft() async {
        var activations = 0
        let page = Node(role: "AXWebArea", children: [
            Node(label: "Sidebar", children: [Node(id: 2, role: "AXButton", label: "Task repo")]),
            Node(label: "Primary pane", children: [Node(role: "AXTextArea", label: "Prompt", value: "Unsent user draft")])
        ])
        let desktop = Desktop(transcripts: Transcript(), foreground: { activations += 1; return false }, snapshot: { page })
        let result = await desktop.prepare(session)
        XCTAssertEqual(result, .draft)
        XCTAssertEqual(activations, 0)
    }

}
