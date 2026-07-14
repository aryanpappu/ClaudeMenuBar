import SwiftUI

struct FloatingIconView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Card background
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.82))
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 6)

            VStack(spacing: 0) {
                // ── Icon + state ──────────────────────────────────
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

                Divider()
                    .background(.white.opacity(0.12))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                // ── Model switcher ────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text("MODEL")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .tracking(1)
                        .padding(.horizontal, 14)

                    HStack(spacing: 6) {
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

                // ── Approve button ───────────────────────────────
                // Approve only appears when the Notification hook fires (Claude is asking for input)
                if appState.state == .waiting {
                    VStack(spacing: 4) {
                        Button(action: { appState.sendApproval() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Approve")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("↵")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.black.opacity(0.5))
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.green)
                            )
                        }
                        .buttonStyle(.plain)

                        if !appState.isAccessibilityGranted {
                            Button(action: { appState.sendApproval() }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 8))
                                    Text("Grant Accessibility to enable")
                                        .font(.system(size: 9))
                                }
                                .foregroundStyle(.yellow.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                Divider()
                    .background(.white.opacity(0.12))
                    .padding(.horizontal, 12)
                    .padding(.top, appState.state == .running || appState.state == .waiting ? 4 : 10)
                    .padding(.bottom, 10)

                // ── Activity counts ───────────────────────────────
                VStack(spacing: 8) {
                    StatRow(label: "This Session", value: appState.sessionMessages, unit: "msgs", color: iconColor)
                    StatRow(label: "This Week",    value: appState.weeklyMessages,  unit: "msgs", color: .blue)

                    // Bottom row: mute all | rain toggle | plan limits link
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
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

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
        .frame(width: 190)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
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

// MARK: Sub-views

private struct ModelPill: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .black : .white.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isActive ? Color.white : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
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
