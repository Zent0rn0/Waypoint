import SwiftUI
import AppKit
import WaypointCore

/// `Waypoint --render-preview <dir>`: renders pages to PNG with sample data, without any screen-recording permission.
/// (AppKit-backed controls — tables, pop-up buttons, switches — may render as placeholders; check those in the real window.)
@MainActor
func renderPreviews(to dir: String) {
    let model = AppModel(preview: true)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func save<V: View>(_ v: V, _ name: String, width: CGFloat, scheme: ColorScheme) {
        let view = v.environment(model).environment(\.colorScheme, scheme).frame(width: width)
            .background(scheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color(red: 0.93, green: 0.93, blue: 0.94))
        let r = ImageRenderer(content: view); r.scale = 2
        if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/" + name)); print("wrote \(name)")
        } else { print("render failed: \(name)") }
    }
    func column<V: View>(_ v: V) -> some View { VStack(alignment: .leading, spacing: 22) { v }.frame(width: Metrics.column).padding(24) }
    for (scheme, tag) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
        save(MenuView(), "menu-\(tag).png", width: 320, scheme: scheme)
        save(column(VStack(alignment: .leading, spacing: 22) { HeroCard(); SetupCard(); StatusTiles(); SessionPanel() }), "overview-\(tag).png", width: Metrics.column + 48, scheme: scheme)
        save(ScrollFreeServers(), "servers-\(tag).png", width: Metrics.column + 48, scheme: scheme)
        save(column(VStack(alignment: .leading, spacing: 22) { PageHeader(screen: .scenarios); ForEach(Playbook.groups, id: \.title) { g in Panel(title: g.title) { ForEach(g.ids.compactMap(Playbook.playbook).indexed(by: \.id)) { i in if i.index > 0 { RowSeparator() }; ScenarioRow(playbook: i.value) } } } }), "scenarios-\(tag).png", width: Metrics.column + 48, scheme: scheme)
    }
}

/// The Servers page without its ScrollView (ImageRenderer cannot render scroll content).
private struct ScrollFreeServers: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Panel(title: "Подписки") { ForEach(model.subscriptions) { SubscriptionRow(sub: $0) } }
            Panel(title: "Мой провайдер") {
                ForEach(model.servers.indexed(by: \.id)) { item in
                    if item.index > 0 { RowSeparator() }
                    ServerRow(server: item.value)
                }
            }
        }
        .frame(width: Metrics.column).padding(24)
    }
}

/// `Waypoint --snapshot <dir>`: opens the real window and saves every page to PNG from the view itself
/// (no screen-recording permission; works while the screen is locked). The app then keeps running normally.
@MainActor
func snapshotWindow(model: AppModel, to dir: String) {
    MainWindow.shared.show(model: model, screen: .overview)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        for s in Screen.allCases {
            model.go(s)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let v = MainWindow.shared.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/\(s.rawValue).png"))
        }
        model.go(.overview)
        print("snapshots done")
    }
}

/// `Waypoint --menu-window`: the menu bar popover in an ordinary window, so it can be looked at and screenshotted.
@MainActor
func showMenuInWindow(model: AppModel) {
    let host = NSHostingController(rootView: MenuView().environment(model).background(AmbientBackdrop()))
    let w = NSWindow(contentViewController: host)
    w.title = "Waypoint — меню"
    w.styleMask = [.titled, .closable]
    w.isReleasedWhenClosed = false
    w.center()
    NSApp.setActivationPolicy(.regular)
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    menuWindowKeepAlive = w
}
@MainActor private var menuWindowKeepAlive: NSWindow?
