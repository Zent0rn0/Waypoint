import SwiftUI
import AppKit

/// The menu bar item and its panel, built by hand instead of `MenuBarExtra`: the system menu-bar window brings its own
/// material, outline and small corner radius that cannot be changed, so any shape of our own showed up as a second one
/// next to it. This panel is a borderless, fully transparent window; the rounded shape and its shadow are drawn by the app.
@MainActor
final class TrayController: NSObject, NSWindowDelegate {
    static let shared = TrayController()
    static let radius: CGFloat = 30
    /// Transparent margin around the visible panel, room for the shadow.
    static let margin = NSEdgeInsets(top: 6, left: 26, bottom: 34, right: 26)

    private var item: NSStatusItem?
    private var panel: TrayWindow?
    private var model: AppModel?
    private var monitors: [Any] = []
    private var anchorTop: CGFloat = 0
    private var iconName = ""
    private var lastHide = Date.distantPast

    func install(model: AppModel) {
        self.model = model
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.target = self
        it.button?.action = #selector(toggle)
        item = it
        refreshIcon()
        Task { @MainActor [weak self] in
            while true { try? await Task.sleep(nanoseconds: 1_000_000_000); self?.refreshIcon() }
        }
    }

    private func refreshIcon() {
        guard let model, let button = item?.button, model.iconName != iconName else { return }
        iconName = model.iconName
        let img = NSImage(systemSymbolName: iconName, accessibilityDescription: "Waypoint")
        img?.isTemplate = true
        button.image = img
    }

    @objc private func toggle() {
        if panel != nil { hide(); return }
        // The click that closes the panel through the outside-click monitor must not open it again.
        if Date().timeIntervalSince(lastHide) < 0.3 { return }
        show()
    }

    private func show() {
        guard let model, let button = item?.button, let buttonWindow = button.window else { return }
        let host = NSHostingController(rootView: TrayChrome { MenuView() }.environment(model))
        host.sizingOptions = [.preferredContentSize]
        let w = TrayWindow(contentRect: NSRect(x: 0, y: 0, width: 412, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.contentViewController = host
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .popUpMenu
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        w.isReleasedWhenClosed = false
        w.delegate = self
        panel = w

        let b = buttonWindow.frame
        anchorTop = b.minY - 2 + Self.margin.top
        let size = host.view.fittingSize
        w.setContentSize(size)
        place(w, centerX: b.midX)
        w.makeKeyAndOrderFront(nil)
        button.highlight(true)

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { self?.hide(); return nil }
            return e
        }) { monitors.append(m) }
    }

    /// Keeps the top edge under the menu bar whatever the content height, and the panel inside the screen.
    private func place(_ w: NSWindow, centerX: CGFloat) {
        var f = w.frame
        f.origin.y = anchorTop - f.height
        f.origin.x = centerX - f.width / 2
        if let s = item?.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            f.origin.x = min(max(f.origin.x, s.minX + 4 - Self.margin.left), s.maxX - 4 + Self.margin.right - f.width)
        }
        w.setFrame(f, display: true)
    }

    func windowDidResize(_ notification: Notification) {
        guard let w = panel, abs(w.frame.maxY - anchorTop) > 0.5 else { return }
        var f = w.frame; f.origin.y = anchorTop - f.height
        w.setFrame(f, display: true)
    }

    func hide() {
        guard panel != nil else { return }
        lastHide = Date()
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        item?.button?.highlight(false)
        panel?.orderOut(nil)
        panel?.contentViewController = nil            // releases the SwiftUI tree, so MenuView's onDisappear runs
        panel = nil
    }
}

/// Borderless panels refuse key status by default; the pop-up menus and buttons inside need it.
final class TrayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The visible shape of the tray panel: one rounded card on the app's backdrop, with a shadow that follows it.
struct TrayChrome<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TrayController.radius, style: .continuous)
        let m = TrayController.margin
        content
            .background { AmbientBackdrop() }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.32), radius: 14, y: 8)
            .padding(EdgeInsets(top: m.top, leading: m.left, bottom: m.bottom, trailing: m.right))
    }
}
