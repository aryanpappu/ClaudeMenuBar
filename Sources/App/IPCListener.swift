import Foundation

// Receives DistributedNotifications posted by the claude-notify CLI tool.
// Forwards the state plus the notification's userInfo (session_id, cwd, remove).
final class IPCListener {
    private let onStateChange: (ClaudeState, [String: String]) -> Void
    private let center = DistributedNotificationCenter.default()

    init(onStateChange: @escaping (ClaudeState, [String: String]) -> Void) {
        self.onStateChange = onStateChange
        register()
    }

    private func register() {
        for state in ClaudeState.allCases {
            center.addObserver(
                self,
                selector: #selector(handle(_:)),
                name: .init("com.claudemenubar.state.\(state.rawValue)"),
                object: nil
            )
        }
    }

    @objc private func handle(_ notification: Notification) {
        let suffix = notification.name.rawValue.components(separatedBy: ".").last ?? ""
        guard let state = ClaudeState(rawValue: suffix) else { return }
        let info = (notification.userInfo as? [String: String]) ?? [:]
        onStateChange(state, info)
    }

    deinit {
        center.removeObserver(self)
    }
}
