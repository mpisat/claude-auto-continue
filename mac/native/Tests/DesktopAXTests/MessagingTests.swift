import ApplicationServices
import Foundation
import XCTest
import ResumeCore
@testable import DesktopAX

@MainActor final class MessagingTests: XCTestCase {
    final class Transcript: TranscriptSource {
        func latest(_ session: Session) throws -> TranscriptSnapshot { .unavailable }
    }
    func testTimeoutCoversAllDescendantObjectsUsingProcessDefault() throws {
        var receivedSystemWide = false
        var receivedTimeout: Float = 0
        let desktop = Desktop(transcripts: Transcript(), foreground: { false }, timeoutSetter: { element, timeout in
            receivedSystemWide = CFEqual(element, AXUIElementCreateSystemWide())
            receivedTimeout = timeout
            return .success
        })
        try desktop.configureMessagingTimeout()
        XCTAssertTrue(receivedSystemWide)
        XCTAssertEqual(receivedTimeout, 0.3)
    }
    func testTimeoutSetupFailureDoesNotProduceUsableCapture() {
        let desktop = Desktop(transcripts: Transcript(), foreground: { false }, timeoutSetter: { _, _ in .invalidUIElement })
        XCTAssertThrowsError(try desktop.configureMessagingTimeout()) { error in
            guard case DesktopError.incompleteTree = error else { return XCTFail("Incorrect failure: \(error)") }
        }
    }
}
