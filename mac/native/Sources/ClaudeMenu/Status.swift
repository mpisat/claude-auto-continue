import Foundation

enum MenuState: Sendable, Equatable { case running, stopped, notInstalled, unavailable }
struct MenuSnapshot: Sendable, Equatable {
    let state: MenuState
    var startsAtLogin: Bool? = nil
    var sessionCount: Int? = nil

    var canStopWatcher: Bool { state == .running || state == .stopped }

    static func parse(exitCode: Int32, output: String) -> MenuSnapshot {
        guard exitCode == 0 else { return MenuSnapshot(state: .unavailable) }
        let lines = output.split(separator: "\n").map(String.init)
        if lines.first == "Watcher: NOT INSTALLED" { return MenuSnapshot(state: .notInstalled) }
        guard lines.count == 3,
              ["Start at login: ON", "Start at login: OFF"].contains(lines[1]),
              lines[2].hasPrefix("Selected sessions: "),
              let count = Int(lines[2].dropFirst("Selected sessions: ".count)), count >= 0 else {
            return MenuSnapshot(state: .unavailable)
        }
        let state: MenuState
        if lines[0].range(of: #"^Watcher: ON \(PID [1-9][0-9]*\)$"#, options: .regularExpression) != nil {
            state = .running
        } else if lines[0] == "Watcher: OFF (not loaded)" || lines[0].hasPrefix("Watcher: NOT RUNNING (loaded, state: ") {
            state = .stopped
        } else { return MenuSnapshot(state: .unavailable) }
        return MenuSnapshot(state: state, startsAtLogin: lines[1] == "Start at login: ON", sessionCount: count)
    }
}
