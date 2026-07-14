import Foundation

// Receives DistributedNotifications posted by the claude-notify CLI tool
final class IPCListener {
    private let onStateChange: (ClaudeState) -> Void
    private let center = DistributedNotificationCenter.default()

    init(onStateChange: @escaping (ClaudeState) -> Void) {
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
        onStateChange(state)
    }

    deinit {
        center.removeObserver(self)
    }
}

