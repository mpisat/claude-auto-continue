import XCTest
@testable import DesktopAX

final class TreeTests: XCTestCase {
    let sid = "local_12345678-1234-1234-1234-123456789abc"
    func page(_ children: [Node], url: String? = nil) -> Node {
        Node(role: "AXWebArea", url: url ?? "https://claude.ai/epitaxy/\(sid)", children: [Node(label: "Primary pane", children: children)])
    }
    func card(_ label: String = "Session limit reached Ask your admin to turn on usage credits. Your session limit resets at 11:50 AM.", id: Int = 7, enabled: Bool = true) -> Node {
        Node(children: [Node(role: "AXStaticText", value: label), Node(id: id, role: "AXButton", label: "Try again", enabled: enabled)])
    }
    func prompt(_ text: String = "") -> Node { Node(role: "AXTextArea", label: "Prompt", value: text) }
    func testCurrentDesktopSplitCard() {
        let liveCard = Node(children: [Node(role: "AXStaticText", value: "Session limit reached"),
            Node(children:[Node(role:"AXStaticText",value:"Ask your admin to turn on usage credits. Your session limit resets at 11:50 AM.")]),
            Node(role:"AXCheckBox",label:"Auto-continue when limits reset",value:"1"),
            Node(id:9,role:"AXButton",label:"Try again")])
        XCTAssertEqual(Tree.retry(in:page([liveCard,prompt()]),sessionID:sid),9)
    }
    func testNativeCountdownCard() {
        let countdown = Node(children: [Node(role:"AXStaticText",value:"Session limit reached"),
            Node(children:[Node(role:"AXStaticText",value:"Auto-resuming at 11:51 AM")]),
            Node(role:"AXCheckBox",label:"Auto-continue when limits reset",value:"1"),
            Node(id:9,role:"AXButton",label:"Try again")])
        XCTAssertEqual(Tree.retry(in:page([countdown,prompt()]),sessionID:sid),9)
    }
    func testUnreadablePromptCannotBeTreatedAsEmpty() {
        let unknown = Node(role:"AXTextArea",label:"Prompt",value:"",valueReadable:false)
        XCTAssertTrue(Tree.hasDraft(in:page([card(),unknown])))
        XCTAssertNil(Tree.retry(in:page([card(),unknown]),sessionID:sid))
    }
    func testComposerAttachmentsBlockRetry() {
        let attached=page([card(),prompt(),Node(role:"AXButton",label:"Remove file")])
        XCTAssertTrue(Tree.hasDraft(in:attached))
        XCTAssertNil(Tree.retry(in:attached,sessionID:sid))
    }
    func testStopWithUnreadableEnabledStateStillBlocks() {
        let transitioning=page([card(),prompt(),Node(role:"AXButton",label:"Stop response",enabled:false)])
        XCTAssertTrue(Tree.busy(in:transitioning))
        XCTAssertNil(Tree.retry(in:transitioning,sessionID:sid))
    }
    func testExactLocalIdentity() {
        XCTAssertEqual(Tree.sessionID(in: page([])), sid)
        XCTAssertNil(Tree.sessionID(in: page([], url: "https://example.com/epitaxy/\(sid)")))
        XCTAssertNil(Tree.sessionID(in: page([], url: "https://claude.ai/epitaxy/\(sid)/unrelated")))
        XCTAssertNil(Tree.sessionID(in: page([], url: "https://claude.ai/epitaxy/local_not-a-uuid")))
    }
    func testScopedUniqueLimitRetry() {
        XCTAssertEqual(Tree.retry(in: page([card(),prompt()]), sessionID: sid), 7)
        XCTAssertNil(Tree.retry(in: page([card(),prompt()]), sessionID: "local_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        XCTAssertNil(Tree.retry(in: page([card(enabled: false),prompt()]), sessionID: sid))
    }
    func testGenericContinueAndUnrelatedRetryAreRejected() {
        XCTAssertNil(Tree.retry(in: page([Node(role:"AXButton",label:"Continue"),prompt()]),sessionID:sid))
        XCTAssertNil(Tree.retry(in: page([Node(children:[Node(role:"AXStaticText",value:"Network error"),Node(role:"AXButton",label:"Try again")]),prompt()]),sessionID:sid))
        XCTAssertNil(Tree.retry(in: page([card("Weekly limit reached"),prompt()]),sessionID:sid))
    }
    func testTranscriptQuoteCannotQualify() {
        let quote = Node(role:"AXStaticText",value:"Session limit reached")
        XCTAssertNil(Tree.retry(in: page([quote,Node(role:"AXButton",label:"Try again"),prompt()]),sessionID:sid))
    }
    func testAmbiguousCardsFailClosed() {
        XCTAssertNil(Tree.retry(in: page([card(),card(id:8),prompt()]),sessionID:sid))
    }
    func testPromptRequiredAndDraftPreserved() {
        XCTAssertFalse(Tree.hasDraft(in:page([prompt()])))
        XCTAssertTrue(Tree.hasDraft(in:page([prompt("my pending message")])))
        XCTAssertTrue(Tree.hasDraft(in:page([])))
        XCTAssertTrue(Tree.hasDraft(in:page([prompt(),prompt()])))
    }
    func testRunningTurnCannotRetry() {
        XCTAssertFalse(Tree.busy(in:page([card(),prompt()])))
        XCTAssertTrue(Tree.busy(in:page([card(),prompt(),Node(role:"AXButton",label:"Stop response")])))
        XCTAssertNil(Tree.retry(in:page([card(),prompt(),Node(role:"AXButton",label:"Stop response")]),sessionID:sid))
    }
    func testSidebarExactAndUnique() {
        let root = Node(children:[Node(label:"Sidebar",children:[Node(id:4,role:"AXButton",label:"My task repo")])])
        XCTAssertEqual(Tree.sidebarButton(in:root,title:"My task",folder:"repo"),4)
        XCTAssertNil(Tree.sidebarButton(in:root,title:"task",folder:"repo"))
        XCTAssertNil(Tree.sidebarButton(in:Node(children:[Node(id:4,role:"AXButton",label:"My task repo")]),title:"My task",folder:"repo"))
        let duplicate=Node(label:"Sidebar",children:[Node(id:4,role:"AXButton",label:"My task repo"),Node(id:5,role:"AXButton",label:"My task repo")])
        XCTAssertNil(Tree.sidebarButton(in:duplicate,title:"My task",folder:"repo"))
    }
    func testDialogsAndMultiplePanesBlock() {
        XCTAssertNil(Tree.retry(in:page([card(),prompt(),Node(role:"AXDialog")]),sessionID:sid))
        let root=Node(children:[page([card(),prompt()]),page([card(),prompt()])])
        XCTAssertNil(Tree.sessionID(in:root))
    }
}
