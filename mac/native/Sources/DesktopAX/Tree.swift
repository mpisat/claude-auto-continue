import Foundation

public struct Node: Equatable, Sendable {
    public var id: Int
    public var role: String
    public var label: String
    public var value: String
    public var url: String
    public var enabled: Bool
    public var valueReadable: Bool
    public var children: [Node]

    public init(id: Int = 0, role: String = "AXGroup", label: String = "", value: String = "", url: String = "", enabled: Bool = true, valueReadable: Bool = true, children: [Node] = []) {
        self.id = id; self.role = role; self.label = label; self.value = value
        self.url = url; self.enabled = enabled; self.valueReadable = valueReadable; self.children = children
    }
}

public enum Tree {
    public static func all(_ root: Node) -> [Node] { [root] + root.children.flatMap(all) }

    public static func sessionID(in root: Node) -> String? {
        let ids = all(root).filter { $0.role == "AXWebArea" }.compactMap { node -> String? in
            let raw = node.url.hasPrefix("claude.ai/") ? "https://" + node.url : node.url
            guard let url = URL(string: raw), url.scheme == "https", url.host == "claude.ai",
                  url.query == nil, url.fragment == nil else { return nil }
            let parts = url.path.split(separator: "/")
            guard parts.count == 2, parts[0] == "epitaxy", parts[1].hasPrefix("local_"),
                  UUID(uuidString: String(parts[1].dropFirst(6))) != nil else { return nil }
            return String(parts[1])
        }
        return ids.count == 1 ? ids.first : nil
    }

    private static func primary(_ root: Node) -> Node? {
        let nodes = all(root).filter { $0.label == "Primary pane" }
        return nodes.count == 1 ? nodes.first : nil
    }

    public static func retry(in root: Node, sessionID: String) -> Int? {
        guard self.sessionID(in: root) == sessionID, let pane = primary(root),
              !hasDraft(in: root), !busy(in: root),
              !all(root).contains(where: { ["AXDialog", "AXSheet"].contains($0.role) }) else { return nil }
        let cards = all(pane).filter { node in
            guard node.role == "AXGroup", node.label.isEmpty else { return false }
            let heading = node.children.contains { child in
                child.role == "AXStaticText" && (child.value == "Session limit reached" || child.value.hasPrefix("Session limit reached "))
            }
            // Countdown replaces reset copy when native auto-continue is armed.
            // The structured transcript supplies the authoritative five-hour reset.
            return heading
        }
        let buttons = cards.flatMap { $0.children.filter {
            $0.role == "AXButton" && $0.label == "Try again" && $0.enabled
        }}
        return buttons.count == 1 ? buttons.first?.id : nil
    }

    public static func sidebarButton(in root: Node, title: String, folder: String) -> Int? {
        let sidebars = all(root).filter { $0.label == "Sidebar" }
        let matches = sidebars.flatMap(all).filter {
            $0.role == "AXButton" && $0.enabled && $0.label == title + " " + folder
        }
        return matches.count == 1 ? matches.first?.id : nil
    }

    public static func hasDraft(in root: Node) -> Bool {
        guard let pane = primary(root) else { return true }
        if all(pane).contains(where: { $0.role == "AXButton" &&
            ($0.label == "Remove file" || $0.label.hasPrefix("Remove image ") || $0.label.hasPrefix("Remove attachment")) }) { return true }
        let fields = all(pane).filter { $0.role == "AXTextArea" && $0.label == "Prompt" }
        guard fields.count == 1, let field = fields.first, field.valueReadable else { return true }
        return !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func busy(in root: Node) -> Bool {
        guard let pane = primary(root) else { return true }
        return all(pane).contains { $0.role == "AXButton" &&
            ["Stop", "Stop response", "Stop Claude", "Stop generating"].contains($0.label) }
    }
}
