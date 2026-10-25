import AppKit
@preconcurrency import ApplicationServices
import Foundation
import ResumeCore

public enum DesktopError: Error { case permission, notRunning, incompleteTree }

@MainActor public final class Desktop: ResumeUI {
    private struct Snapshot {
        let root: Node
        let elements: [Int: AXUIElement]
    }
    private var captureHealth = CaptureHealth()
    private var originalID: String?
    private var lastSelectedID: String?
    private let transcripts: any TranscriptSource
    private var navigationOverride: ((Session) async -> Readiness)?
    private var foregroundOverride: (() async -> Bool)?
    private var snapshotOverride: (() throws -> Node)?
    private var timeoutSetter: ((AXUIElement, Float) -> AXError)?
    public private(set) var lastDiagnostic = "not inspected"
    private var sessionDiagnostics: [String: String] = [:]
    public func diagnostic(for sessionID: String) -> String? { sessionDiagnostics[sessionID] }

    public init(transcripts: any TranscriptSource) { self.transcripts = transcripts }
    internal init(transcripts: any TranscriptSource, navigation: ((Session) async -> Readiness)? = nil,
                  foreground: @escaping () async -> Bool, snapshot: (() throws -> Node)? = nil,
                  timeoutSetter: ((AXUIElement, Float) -> AXError)? = nil) {
        self.transcripts = transcripts
        navigationOverride = navigation
        foregroundOverride = foreground
        snapshotOverride = snapshot
        self.timeoutSetter = timeoutSetter
    }
    public static var trusted: Bool { AXIsProcessTrusted() }

    public static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        captureHealth.record(error)
        if ![AXError.success, .attributeUnsupported, .noValue].contains(error) {
            lastDiagnostic = "ax_" + name + "_error_" + String(error.rawValue)
        }
        return error == .success ? value : nil
    }
    private func text(_ element: AXUIElement, _ name: String) -> String {
        attribute(element, name) as? String ?? ""
    }
    internal func configureMessagingTimeout() throws {
        let result = (timeoutSetter ?? AXUIElementSetMessagingTimeout)(AXUIElementCreateSystemWide(), 0.3)
        guard result == .success else { lastDiagnostic = "AX timeout setup failed: \(result.rawValue)"; throw DesktopError.incompleteTree }
    }

    private func capture() throws -> Snapshot {
        if let snapshotOverride { return Snapshot(root: try snapshotOverride(), elements: [:]) }
        guard Self.trusted else { throw DesktopError.permission }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
        guard apps.count == 1, let app = apps.first else { throw DesktopError.notRunning }
        captureHealth = CaptureHealth()
        lastDiagnostic = ""
        let root = AXUIElementCreateApplication(app.processIdentifier)
        try configureMessagingTimeout()
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] else { throw DesktopError.incompleteTree }
        let deadline = Date().addingTimeInterval(10)
        var elements: [Int: AXUIElement] = [:]
        func walk(_ element: AXUIElement, depth: Int) throws -> Node {
            guard depth < 80, elements.count < 12000, Date() < deadline else { throw DesktopError.incompleteTree }
            let id = elements.count + 1
            elements[id] = element
            let role = text(element, kAXRoleAttribute)
            guard !role.isEmpty else { throw DesktopError.incompleteTree }
            let title = text(element, kAXTitleAttribute)
            let label = title.isEmpty ? text(element, kAXDescriptionAttribute) : title
            let needsValue = ["AXStaticText", "AXTextArea", "AXTextField"].contains(role)
            let rawValue = needsValue ? attribute(element, kAXValueAttribute) : nil
            let value = rawValue as? String ?? ""
            let valueReadable = !needsValue || rawValue is String
            let url = role == "AXWebArea" ? (attribute(element, kAXURLAttribute) as? URL)?.absoluteString ?? text(element, kAXURLAttribute) : ""
            let enabled = role == "AXButton" ? (attribute(element, kAXEnabledAttribute) as? Bool ?? false) : true
            // Native controls are leaves for our policy. Reading their decorative
            // Chromium descendants can race icon disposal and adds no gate data.
            let leaf = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXRadioButton", "AXTextArea", "AXStaticText", "AXImage", "AXLink"].contains(role)
            let rawChildren = leaf ? nil : attribute(element, kAXChildrenAttribute)
            if rawChildren != nil && !(rawChildren is [AXUIElement]) { captureHealth.invalidType() }
            let children = rawChildren as? [AXUIElement] ?? []
            return Node(id: id, role: role, label: label, value: value, url: url, enabled: enabled, valueReadable: valueReadable,
                        children: try children.map { try walk($0, depth: depth + 1) })
        }
        let nodes = try windows.map { try walk($0, depth: 0) }
        return Snapshot(root: try captureHealth.validated(Node(role: "AXApplication", children: nodes)), elements: elements)
    }

    private func readiness(_ snapshot: Snapshot, for session: Session) -> Readiness {
        guard Tree.sessionID(in: snapshot.root) == session.id else { return .wrongIdentity }
        if Tree.busy(in: snapshot.root) { return .busy }
        if Tree.hasDraft(in: snapshot.root) { return .draft }
        return Tree.retry(in: snapshot.root, sessionID: session.id) == nil ? .notLimited : .ready
    }

    public func prepare(_ session: Session) async -> Readiness {
        lastDiagnostic = ""
        defer { sessionDiagnostics[session.id] = lastDiagnostic }
        let background = await navigateForPreparation(session)
        let detail = lastDiagnostic
        guard !Task.isCancelled else { lastDiagnostic = "navigation cancelled"; return .unavailable }
        guard background == .wrongIdentity || background == .unavailable else {
            if lastDiagnostic.isEmpty { lastDiagnostic = background.rawValue }
            return background
        }
        guard await foregroundClaude() else {
            lastDiagnostic = "could not bring Claude forward after \(background.rawValue): \(lastDiagnostic)"
            return .unavailable
        }
        guard !Task.isCancelled else { lastDiagnostic = "navigation cancelled"; return .unavailable }
        // Activation can wake native auto-continue. Capture and evaluate again;
        // the coordinator still rechecks the transcript before any Retry action.
        let result = await navigateForPreparation(session)
        lastDiagnostic = "foreground fallback after \(background.rawValue) (\(detail)); result \(result.rawValue): \(lastDiagnostic)"
        return result
    }

    private func navigateForPreparation(_ session: Session) async -> Readiness {
        if let navigationOverride { return await navigationOverride(session) }
        return await navigate(session)
    }

    private func foregroundClaude() async -> Bool {
        if let foregroundOverride { return await foregroundOverride() }
        guard Self.trusted else { lastDiagnostic = "Accessibility permission missing"; return false }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
        guard apps.count == 1, let app = apps.first else { lastDiagnostic = "Claude is not uniquely available"; return false }
        if app.isActive { return true }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let result = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard result == .success else { lastDiagnostic = "foreground request failed: \(result.rawValue)"; return false }
        for _ in 0..<20 {
            guard !Task.isCancelled else { return false }
            if app.isActive { return true }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        lastDiagnostic = "Claude did not become active within two seconds"
        return false
    }

    private func navigate(_ session: Session) async -> Readiness {
        do {
            let first = try capture()
            let current = Tree.sessionID(in: first.root)
            if originalID == nil { originalID = current }
            if current == session.id {
                lastSelectedID = session.id
                return readiness(first, for: session)
            }
            // Never navigate away while a person has a draft in the current session.
            if Tree.hasDraft(in: first.root) { return .draft }
            guard let id = Tree.sidebarButton(in: first.root, title: session.title,
                                             folder: URL(fileURLWithPath: session.cwd).lastPathComponent),
                  let button = first.elements[id] else { return .unavailable }
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return .unavailable }
            lastSelectedID = session.id
            var observed = current
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                let next = try capture()
                observed = Tree.sessionID(in: next.root)
                if Tree.sessionID(in: next.root) == session.id {
                    let state = readiness(next, for: session)
                    if state != .draft || Tree.all(next.root).contains(where: { $0.role == "AXTextArea" && $0.label == "Prompt" }) {
                        return state
                    }
                }
            }
            lastDiagnostic = "chat selection timed out; expected \(session.id); observed \(observed ?? "unknown")"
            return .wrongIdentity
        } catch {
            lastDiagnostic = String(describing: error) + ":" + lastDiagnostic
            return .unavailable
        }
    }

    public func pressRetry(_ session: Session, expected: LimitEvent) async -> PressOutcome {
        defer { sessionDiagnostics[session.id] = lastDiagnostic }
        // The AX action uses a fresh handle. A stale handle or timeout is ambiguous,
        // never a reason to send a second turn. Desktop's own sender is independent.
        do {
            let before = try transcripts.latest(session)
            guard before == .limited(expected), expected.resetsAt <= Date() else {
                lastDiagnostic = "Retry skipped: transcript changed or reset is still in the future"
                return .definitelyNotSent
            }
            let snapshot = try capture()
            let state = readiness(snapshot, for: session)
            guard state == .ready else {
                lastDiagnostic = "Retry skipped: " + state.rawValue
                return .definitelyNotSent
            }
            guard let id = Tree.retry(in: snapshot.root, sessionID: session.id), let button = snapshot.elements[id] else {
                lastDiagnostic = "Retry skipped: verified control is unavailable"
                return .definitelyNotSent
            }
            guard try transcripts.latest(session) == before else {
                lastDiagnostic = "Retry skipped: transcript changed before pressing"
                return .definitelyNotSent
            }
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            lastDiagnostic = result == .success ? "Retry pressed; awaiting assistant progress" : "Retry outcome uncertain; AX error \(result.rawValue)"
            return result == .success ? .pressed : .ambiguous
        } catch { lastDiagnostic = String(describing: error); return .definitelyNotSent }
    }

    public func diagnose(_ session: Session, foreground: Bool = false) async -> Readiness {
        if foreground {
            guard await foregroundClaude() else { return .unavailable }
        }
        let result = await prepare(session)
        if foreground { lastDiagnostic = "foreground verified; " + lastDiagnostic }
        return result
    }

    public func restore(_ sessions: [Session]) async {
        defer { self.originalID = nil; self.lastSelectedID = nil }
        guard let originalID, originalID != lastSelectedID,
              let session = sessions.first(where: { $0.id == originalID }),
              let snapshot = try? capture(), Tree.sessionID(in: snapshot.root) == lastSelectedID,
              !Tree.hasDraft(in: snapshot.root),
              let id = Tree.sidebarButton(in: snapshot.root, title: session.title,
                                         folder: URL(fileURLWithPath: session.cwd).lastPathComponent),
              let button = snapshot.elements[id] else { return }
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(250))
    }
}
