import SwiftUI

struct FloatingIconView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Card background
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.82))

            VStack(spacing: 0) {
                iconHeader

                sectionDivider

                // ── Active sessions ───────────────────────────────
                sessionsSection

                sectionDivider

                // ── Model switcher ────────────────────────────────
                modelSection

                sectionDivider

                // ── Activity + sound ──────────────────────────────
                statsSection
            }
            .padding(.bottom, 14)
            // Report the natural content height so the panel can size to it.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                }
            )

            // Dismiss button on hover
            if isHovered {
                Button {
                    appState.showFloatingIcon = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white.opacity(0.6))
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .padding(8)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .frame(width: 210)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 6)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onPreferenceChange(PanelHeightKey.self) { height in
            if height > 0 { appState.panelContentHeight = height }
        }
    }

    // MARK: Header (aggregate state)

    private var iconHeader: some View {
        VStack(spacing: 4) {
            Image(systemName: iconName)
                .symbolRenderingMode(renderingMode)
                .foregroundStyle(iconColor)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace.offUp)))
                .symbolEffect(.breathe.wholeSymbol, isActive: appState.state == .running)
                .symbolEffect(.wiggle.wholeSymbol, options: .speed(0.5).repeating, isActive: appState.state == .waiting)
                .symbolEffect(.bounce.wholeSymbol, value: appState.state == .done ? 1 : 0)
                .font(.system(size: 42, weight: .light))

            Text(stateLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconColor.opacity(0.9))
                .animation(.easeInOut(duration: 0.2), value: stateLabel)
        }
        .padding(.top, 16)
    }

    private var sectionDivider: some View {
        Divider()
            .background(.white.opacity(0.12))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
    }

    // MARK: Collapsible section header

    private func sectionHeader(_ title: String, count: Int? = nil, isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .tracking(1)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Sessions section

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("SESSIONS", count: appState.activeSessions.count, isExpanded: appState.sessionsExpanded) {
                appState.sessionsExpanded.toggle()
            }

            if appState.sessionsExpanded {
                if appState.activeSessions.isEmpty {
                    Text("No active sessions")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                } else {
                    // Deterministic height (hug up to 5 rows, then scroll). A
                    // greedy ScrollView with maxHeight would make the panel's
                    // measured content height circular and break resizing.
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(appState.activeSessions) { session in
                                SessionRow(
                                    session: session,
                                    accessibilityGranted: appState.isAccessibilityGranted,
                                    oneClickApprove: appState.oneClickApprove && !session.needsAnswer,
                                    onApprove: { appState.sendApproval(for: session.id) },
                                    onFocus: { appState.focusTerminal(for: session) }
                                )
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    .frame(height: CGFloat(min(appState.activeSessions.count, 5)) * 38)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.activeSessions.map(\.id))
    }

    // MARK: Model section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("MODEL", isExpanded: appState.modelExpanded) {
                appState.modelExpanded.toggle()
            }

            if appState.modelExpanded {
                HStack(spacing: 4) {
                    ForEach(appState.modelOptions) { option in
                        ModelPill(
                            label: option.label,
                            isActive: appState.currentModel == option.id
                        ) {
                            appState.setModel(option.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    // MARK: Activity + sound section

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ACTIVITY", isExpanded: appState.statsExpanded) {
                appState.statsExpanded.toggle()
            }

            if appState.statsExpanded {
                VStack(spacing: 8) {
                    StatRow(label: "Today", value: appState.todayMessages, unit: "msgs", color: iconColor)
                    StatRow(label: "This Week",    value: appState.weeklyMessages,  unit: "msgs", color: .blue)
                    soundRow
                }
                .padding(.horizontal, 14)
            }
        }
    }

    // Bottom row: mute all | rain toggle | plan limits link
    private var soundRow: some View {
        HStack(spacing: 6) {
            Button {
                appState.isMuted.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: appState.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9))
                    Text(appState.isMuted ? "Muted" : "Sound on")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(appState.isMuted ? .orange.opacity(0.8) : .white.opacity(0.35))
            }
            .buttonStyle(.plain)

            Button {
                appState.isRainMuted.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: appState.isRainMuted ? "cloud.slash.fill" : "cloud.rain.fill")
                        .font(.system(size: 9))
                    Text("Rain")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(appState.isRainMuted ? .orange.opacity(0.8) : .white.opacity(0.35))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/limits")!)
            } label: {
                HStack(spacing: 3) {
                    Text("Plan limits")
                        .font(.system(size: 9, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8))
                }
                .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    // MARK: Computed

    private var iconName: String {
        switch appState.state {
        case .idle:    "brain"
        case .running: "brain.filled.head.profile"
        case .waiting: "bell.badge.fill"
        case .done:    "checkmark.circle.fill"
        }
    }

    private var renderingMode: SymbolRenderingMode {
        appState.state == .waiting ? .multicolor : .hierarchical
    }

    private var iconColor: Color {
        switch appState.state {
        case .idle:    .white.opacity(0.5)
        case .running: .blue
        case .waiting: .orange
        case .done:    .green
        }
    }

    private var stateLabel: String {
        switch appState.state {
        case .idle:    "Ready"
        case .running: "Thinking..."
        case .waiting: "Waiting"
        case .done:    "Done ✓"
        }
    }
}

// Reports the panel's natural content height up to the NSPanel wrapper.
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: Sub-views

private struct ModelPill: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .black : .white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)   // four pills share the row evenly
                .background(
                    Capsule()
                        .fill(isActive ? Color.white : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

private struct SessionRow: View {
    let session: Session
    let accessibilityGranted: Bool
    let oneClickApprove: Bool
    let onApprove: () -> Void
    let onFocus: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if session.state == .waiting {
                // With one-click Approve off (the default) the button only
                // brings the terminal forward; the user answers there.
                Button(action: oneClickApprove ? onApprove : onFocus) {
                    HStack(spacing: 3) {
                        Image(systemName: buttonIcon)
                            .font(.system(size: 9, weight: .bold))
                        Text(buttonLabel)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(buttonColor)
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()   // keep full "Approve" label; let the name truncate instead
            } else {
                Text(stateLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(dotColor.opacity(0.9))
            }
        }
        .frame(height: 34)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }   // click a row → raise its terminal
    }

    private var buttonLabel: String {
        if !accessibilityGranted { return "Grant" }
        return oneClickApprove ? "Approve" : "Open"
    }

    private var buttonIcon: String {
        if !accessibilityGranted { return "lock.fill" }
        return oneClickApprove ? "checkmark" : "arrow.up.forward.app"
    }

    private var buttonColor: Color {
        if !accessibilityGranted { return .yellow }
        return oneClickApprove ? .green : .orange
    }

    // When waiting, lead with what's being requested ("wants Bash"); otherwise
    // "branch · what it's doing", falling back to the working directory.
    private var subtitle: String {
        if session.state == .waiting, let req = session.pendingRequest, !req.isEmpty {
            return "wants \(req)"
        }
        var parts: [String] = []
        if let b = session.branch, !b.isEmpty { parts.append(b) }
        if let a = session.activity, !a.isEmpty { parts.append(a) }
        if parts.isEmpty { return abbreviatedPath }
        return parts.joined(separator: " · ")
    }

    private var abbreviatedPath: String {
        let home = NSHomeDirectory()
        return session.cwd.hasPrefix(home) ? "~" + session.cwd.dropFirst(home.count) : session.cwd
    }

    private var dotColor: Color {
        switch session.state {
        case .idle:    .white.opacity(0.4)
        case .running: .blue
        case .waiting: .orange
        case .done:    .green
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .idle:    "Ready"
        case .running: "Working"
        case .waiting: "Waiting"
        case .done:    "Done"
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: Int
    let unit: String
    let color: Color

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                Circle()
                    .fill(color.opacity(0.8))
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Text("\(value) \(unit)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
