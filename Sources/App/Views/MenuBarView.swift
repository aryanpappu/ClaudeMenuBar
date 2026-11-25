import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            statusRow
            Divider().padding(.vertical, 6)
            actionButtons
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18))
                    .foregroundStyle(.purple)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Menu Bar")
                    .font(.headline)
                Text("Unofficial monitor for Claude Code · v\(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            PulseDot(state: appState.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(stateLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .animation(.default, value: appState.state)
                if let date = appState.lastActivity {
                    Text("Updated \(date, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var actionButtons: some View {
        VStack(spacing: 4) {
            MenuRowButton(title: "Open Terminal", icon: "terminal") {
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
            MenuRowToggle(
                title: "Floating Icon",
                icon: "square.on.square",
                isOn: appState.showFloatingIcon
            ) {
                appState.showFloatingIcon.toggle()
            }
            MenuRowToggle(
                title: "Launch at Login",
                icon: "power.circle",
                isOn: appState.launchAtLoginEnabled
            ) {
                appState.toggleLaunchAtLogin()
            }
            MenuRowToggle(
                title: "Notifications",
                icon: "bell",
                isOn: appState.notificationsEnabled
            ) {
                appState.notificationsEnabled.toggle()
            }
            MenuRowToggle(
                title: "Show Prompt in Banners",
                icon: "text.bubble",
                isOn: appState.notificationPreviews
            ) {
                appState.notificationPreviews.toggle()
            }
            MenuRowToggle(
                title: "One-Click Approve",
                icon: "checkmark.shield",
                isOn: appState.oneClickApprove
            ) {
                appState.oneClickApprove.toggle()
            }
            if appState.oneClickApprove {
                Text("Types y + Return into the matching terminal. Needs Accessibility permission.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if DEBUG
            Divider().padding(.vertical, 2)
            MenuRowButton(title: "Debug: Force Running", icon: "play.fill") {
                appState.apply(.running)
            }
            MenuRowButton(title: "Debug: Force Idle", icon: "stop.fill") {
                appState.apply(.idle)
            }
            #endif
            Divider().padding(.vertical, 2)
            MenuRowButton(title: "About / GitHub", icon: "info.circle") {
                NSWorkspace.shared.open(URL(string: "https://github.com/aryanpappu/ClaudeMenuBar")!)
            }
            MenuRowButton(title: "Quit", icon: "power", tint: .red) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var stateLabel: String {
        switch appState.state {
        case .idle:    "Idle — ready"
        case .running: "Thinking..."
        case .waiting: "Waiting for your input"
        case .done:    "Task complete ✓"
        }
    }
}

// MARK: - Sub-views

struct PulseDot: View {
    let state: ClaudeState
    @State private var pulse = false

    var body: some View {
        ZStack {
            if state == .running {
                Circle()
                    .fill(dotColor.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 2.0 : 1.0)
                    .opacity(pulse ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
        }
        .onAppear { pulse = true }
        .onChange(of: state) { _, _ in pulse = true }
    }

    private var dotColor: Color {
        switch state {
        case .idle:    .gray
        case .running: .blue
        case .waiting: .orange
        case .done:    .green
        }
    }
}

struct MenuRowButton: View {
    let title: String
    let icon: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct MenuRowToggle: View {
    let title: String
    let icon: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? .green : .secondary)
                    .animation(.easeInOut(duration: 0.2), value: isOn)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
