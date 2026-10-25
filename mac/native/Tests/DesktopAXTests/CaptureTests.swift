import ApplicationServices
import XCTest
@testable import DesktopAX

final class CaptureTests: XCTestCase {
    func testTimeoutCannotProduceAnActionableSnapshot() {
        var health = CaptureHealth()
        health.record(.cannotComplete)
        XCTAssertThrowsError(try health.validated(Node())) { error in
            guard case DesktopError.incompleteTree = error else { return XCTFail("Wrong failure: \(error)") }
        }
    }
    func testUnsupportedLeafAttributesAreAllowed() throws {
        var health = CaptureHealth()
        health.record(.attributeUnsupported)
        health.record(.noValue)
        XCTAssertEqual(try health.validated(Node()), Node())
    }
    func testWrongAttributeTypeCannotProduceAnActionableSnapshot() {
        var health = CaptureHealth()
        health.invalidType()
        XCTAssertThrowsError(try health.validated(Node()))
    }
}
