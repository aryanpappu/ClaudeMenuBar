import AppKit
import SwiftUI
import Combine

final class FloatingPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()

    private let panelWidth: CGFloat = 210

    init(appState: AppState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: appState.panelContentHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        let root = AnyView(FloatingIconView().environmentObject(appState))
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: panelWidth, height: appState.panelContentHeight)
        hostingView = view
        contentView = view

        placeOnScreen()

        // Resize to whatever height the SwiftUI content reports — handles
        // sessions coming/going and any section being expanded/collapsed.
        appState.$panelContentHeight
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] height in
                self?.resize(to: height)
            }
            .store(in: &cancellables)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: Private

    private func placeOnScreen() {
        let mousePos = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mousePos) })
                     ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: vf.maxX - panelWidth - 24,
            y: vf.minY + 60
        ))
    }

    private func resize(to height: CGFloat) {
        // The panel is anchored near the bottom of the screen, so keep the
        // BOTTOM edge pinned (origin.y fixed) and grow upward. Growing downward
        // would push expanded content off the bottom of the screen.
        var f = frame
        f.size.height = height
        hostingView?.frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
        setFrame(f, display: true, animate: true)
    }
}
