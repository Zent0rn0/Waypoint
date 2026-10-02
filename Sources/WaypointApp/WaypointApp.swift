import SwiftUI

@main
struct WaypointApp: App {
    @State private var model: AppModel

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            _ = NSApplication.shared
            MainActor.assumeIsolated { renderPreviews(to: args[i + 1]) }
            exit(0)
        }
        let m = AppModel()
        _model = State(initialValue: m)
        // First run (or `--show-window [screen]`): open the dashboard once the app has finished launching.
        let showArg = args.firstIndex(of: "--show-window")
        let screenArg = showArg.flatMap { i in i + 1 < args.count ? Screen(rawValue: args[i + 1]) : nil }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                m.applyAppearance()
                TrayController.shared.install(model: m)
                if args.contains("--menu-window") { showMenuInWindow(model: m); return }   // development aid: the tray popover as a normal window
                if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { snapshotWindow(model: m, to: args[i + 1]); return }
                if showArg != nil || m.showOnboarding { MainWindow.shared.show(model: m, screen: screenArg) }
            }
        }
    }

    var body: some Scene {
        // An App needs a scene, and this one creates no window: the real menu bar item and its panel are built in TrayController
        // (a `Settings` scene here opened an empty settings window at launch).
        MenuBarExtra("Waypoint", isInserted: .constant(false)) { EmptyView() }
    }
}
