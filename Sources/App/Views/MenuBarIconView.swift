import SwiftUI

struct MenuBarIconView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(renderingMode)
            .foregroundStyle(iconColor)
            // Smooth morph between symbols when state changes
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace.offUp)))
            // Breathing pulse while Claude is working
            .symbolEffect(.breathe.wholeSymbol, isActive: appState.state == .running)
            // Gentle repeating wiggle while waiting for input
            .symbolEffect(.wiggle.wholeSymbol, options: .speed(0.5).repeating, isActive: appState.state == .waiting)
            // One bounce on task completion
            .symbolEffect(.bounce.wholeSymbol, value: appState.state == .done ? 1 : 0)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 20, height: 20)
            // Smooth color crossfade on state change
            .animation(.easeInOut(duration: 0.4), value: iconColor)
            .animation(.easeInOut(duration: 0.3), value: iconName)
    }

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
        case .idle:    .primary
        case .running: .blue
        case .waiting: .orange
        case .done:    .green
        }
    }
}
