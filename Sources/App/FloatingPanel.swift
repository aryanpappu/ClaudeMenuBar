import AppKit
import SwiftUI
import Combine

final class FloatingPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private var cancellable: AnyCancellable?

    private let panelWidth: CGFloat  = 190
    private let baseHeight: CGFloat  = 270   // no approve button
    private let expandedHeight: CGFloat = 310 // with approve button

    init(appState: AppState) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 190, height: 270),
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
        view.frame = NSRect(x: 0, y: 0, width: panelWidth, height: baseHeight)
        hostingView = view
        contentView = view

        placeOnScreen()

        // Resize panel when waiting state (approve button) appears/disappears
        cancellable = appState.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self else { return }
                let h = (newState == .waiting) ? self.expandedHeight : self.baseHeight
                self.resize(to: h)
            }
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
        var f = frame
        let topEdge = f.maxY          // keep the top edge fixed
        f.size.height = height
        f.origin.y = topEdge - height
        hostingView?.frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
        setFrame(f, display: true, animate: true)
    }
}
