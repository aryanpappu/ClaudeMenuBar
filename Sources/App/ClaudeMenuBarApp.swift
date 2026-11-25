import AppKit
import SwiftUI

// AppDelegate — owns the status item, popover, and floating panel
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var iconHosting: NSHostingView<AnyView>?
    private var floatingPanel: FloatingPanel?   // strong ref in delegate — panel can't be released

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.setup()
        setupStatusItem()
        setupFloatingPanel()
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        let icon = AnyView(MenuBarIconView().environmentObject(AppState.shared))
        let hosting = NSHostingView(rootView: icon)
        hosting.frame = NSRect(x: 0, y: 0, width: 28, height: 22)
        iconHosting = hosting
        button.addSubview(hosting)
        button.frame = hosting.frame
        button.action = #selector(togglePopover)
        button.target = self
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let pop = popover, pop.isShown {
            pop.performClose(nil)
            return
        }
        let pop = NSPopover()
        pop.behavior = .transient
        let controller = NSHostingController(
            rootView: MenuBarView().environmentObject(AppState.shared)
        )
        controller.sizingOptions = .preferredContentSize   // popover follows the SwiftUI size
        pop.contentViewController = controller
        popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: Floating panel

    private func setupFloatingPanel() {
        let panel = FloatingPanel(appState: AppState.shared)
        floatingPanel = panel                   // retain in AppDelegate
        AppState.shared.floatingPanel = panel   // also pass to AppState for show/hide control
        if AppState.shared.showFloatingIcon { panel.orderFrontRegardless() }
    }
}
