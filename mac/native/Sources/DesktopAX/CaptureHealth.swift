import ApplicationServices

struct CaptureHealth {
    private(set) var failed = false
    mutating func record(_ error: AXError) {
        if ![AXError.success, .attributeUnsupported, .noValue].contains(error) { failed = true }
    }
    mutating func invalidType() { failed = true }
    func validated(_ root: Node) throws -> Node {
        guard !failed else { throw DesktopError.incompleteTree }
        return root
    }
}
