import SwiftUI
import AppKit
import WaypointCore

/// The dashboard window (System Settings proportions: fixed width, resizable height).
/// The app is otherwise a menu bar accessory; the Dock icon appears only while the window is open.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    static let width: CGFloat = 900
    private var window: NSWindow?
    var contentView: NSView? { window?.contentView }
    private weak var model: AppModel?

    func show(model: AppModel, screen: Screen? = nil) {
        self.model = model
        if let screen { model.go(screen) }
        if window == nil {
            let host = NSHostingController(rootView: DashboardView().environment(model))
            host.sizingOptions = []                                          // the window decides its size, not SwiftUI's fitting size
            host.view.frame = NSRect(x: 0, y: 0, width: Self.width, height: 640)
            let w = FixedHeightWindow(contentViewController: host)
            w.title = "Waypoint"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true                               // no title bar strip: the traffic lights sit on the sidebar glass
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.isMovableByWindowBackground = true                             // drag the window by any empty part of the backdrop
            let tb = NSToolbar(identifier: "waypoint.main")                  // empty toolbar: gives the traffic lights their usual inset
            tb.showsBaselineSeparator = false
            w.toolbar = tb
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: Self.width, height: 640))
            w.contentMinSize = NSSize(width: Self.width, height: 520)
            w.contentMaxSize = NSSize(width: Self.width, height: 4000)
            w.collectionBehavior = [.fullScreenNone]
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("WaypointMainWindow.v3")
            w.delegate = self
            w.center()
            window = w
        }
        if let w = window, w.contentLayoutRect.width != Self.width {        // never let anything widen the window
            var f = w.frame; f.size.width = Self.width; w.setFrame(f, display: true)
        }
        (window as? FixedHeightWindow)?.lockedHeight = window?.frame.height
        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        NSApp.presentationOptions = []
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // macOS does not bring up the menu bar of an app that has just switched from "menu bar only" to a regular app:
        // the bar stays empty/hidden until the app is activated again. Hand focus to the Dock for a moment and take it back.
        if wasAccessory {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.makeKeyAndOrderFront(nil)
            }
        }
        model.visible = true
    }

    /// Dragging an edge keeps the System Settings width; only the height follows the mouse.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: sender.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: 10)).width, height: frameSize.height)
    }

    func windowWillClose(_ notification: Notification) {
        model?.visible = false
        NSApp.setActivationPolicy(.accessory)
    }
}

/// macOS 26 layout built by hand (a system split view would bring its own opaque sidebar material):
/// one ambient backdrop for the whole window, a quiet sidebar (rows on the backdrop, traffic lights on top),
/// and the pages on the same backdrop with glass back/forward buttons above them.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    static let sidebarWidth: CGFloat = 230

    var body: some View {
        @Bindable var m = model
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                NavBar()
                ZStack(alignment: .bottom) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .id(model.screen)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.14)), removal: .identity))
                        .clipped()                                           // pages scroll inside their own area, never under the back/forward bar
                    if let t = model.toast {
                        Text(t).font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
                            .glassCapsule().padding(.bottom, 18)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: model.toast)
                            }
        }
        .ignoresSafeArea()
        .background(IsolatedBackdrop().ignoresSafeArea().allowsHitTesting(false))
        .sheet(isPresented: $m.showOnboarding) { OnboardingView().environment(model) }
    }

    /// Quiet on purpose: no card and no border, just rows on the backdrop; the selected row is a faint lightening, not an accent bar.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarRow(selected: model.screen == .overview) { model.go(.overview) } content: { SidebarStatusRow() }
                .padding(.bottom, 10)
            ForEach(Screen.groups.indices, id: \.self) { i in
                if i > 0 { Spacer().frame(height: 14) }
                ForEach(Screen.groups[i]) { s in
                    SidebarRow(selected: model.screen == s) { model.go(s) } content: {
                        HStack(spacing: 9) {
                            IconTile(symbol: s.symbol, color: s.color, size: 20).opacity(0.85)
                            Text(s.title).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 46)                                                  // room for the traffic lights
        .padding(.horizontal, 10)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.14))                              // barely darker than the backdrop, so it reads as a side, not a panel
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1) }
    }

    @ViewBuilder private var content: some View {
        switch model.screen {
        case .overview: OverviewPage()
        case .scenarios: ScenariosPage()
        case .services: ServicesPage()
        case .apps: AppsPage()
        case .sites: SitesPage()
        case .activity: ActivityPage()
        case .servers: ServersPage()
        case .diagnostics: DiagnosticsPage()
        case .settings: SettingsPage()
        }
    }
}

struct SidebarRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(selected ? 0.10 : (hover ? 0.05 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.78))
        .animation(.snappy(duration: 0.18), value: selected)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Back / forward, in the same glass as the rest (where a toolbar would be).
struct NavBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 0) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left").frame(width: 30, height: 26) }
                .disabled(model.backStack.isEmpty).help("Назад")
            Button { model.goForward() } label: { Image(systemName: "chevron.right").frame(width: 30, height: 26) }
                .disabled(model.forwardStack.isEmpty).help("Вперёд")
        }
        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .glassCapsule()
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { ThemeButton() }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 2)
    }
}

/// Light / dark switch at the top right of every page.
struct ThemeButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button { model.toggleAppearance() } label: {
            Image(systemName: scheme == .dark ? "sun.max.fill" : "moon.fill").font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 26)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .glassCapsule()
        .help(scheme == .dark ? "Светлая тема" : "Тёмная тема")
    }
}

/// Top sidebar row, like «Аккаунт Apple» in System Settings: the app itself and its state in one line.
struct SidebarStatusRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let h = model.hero
        HStack(spacing: 10) {
            BrandMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Waypoint").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(h.color).frame(width: 6, height: 6)
                    Text(h.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// SwiftUI rewrites the window's size limits from the page's ideal size, so opening a long list used to grow the window.
/// Here only the user changes the height (live resize); every other frame change keeps the height they chose.
final class FixedHeightWindow: NSWindow {
    var lockedHeight: CGFloat?
    private var observer: NSObjectProtocol?

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockedHeight = self?.frame.height }
        }
    }

    private func pinned(_ r: NSRect) -> NSRect {
        guard !inLiveResize, let h = lockedHeight, abs(r.height - h) > 0.5 else { return r }
        var f = r
        f.origin.y += f.height - h           // keep the title bar where it was
        f.size.height = h
        return f
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) { super.setFrame(pinned(frameRect), display: flag) }
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) { super.setFrame(pinned(frameRect), display: displayFlag, animate: animateFlag) }
}

