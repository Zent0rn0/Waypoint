import SwiftUI
import WaypointCore

struct AppsPage: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var detail: AppInfo?          // owned by the page: a row moves between sections when it gets a rule

    private static let plumbing = ["/usr/libexec/", "/usr/sbin/", "/sbin/", "/System/Library/", "/usr/bin/", "/Library/Apple/"]

    private func matches(_ name: String) -> Bool { query.isEmpty || name.localizedCaseInsensitiveContains(query) }

    private var online: [AppInfo] {
        Set(model.connections.compactMap(\.appPath)).sorted()
            .filter { p in AppPath.isValid(p) && !Self.plumbing.contains(where: p.hasPrefix) }
            .map { AppInfo(path: $0, name: AppPath.displayName($0), uses: 0) }
            .filter { matches($0.name) }
    }
    private var withRules: [AppInfo] {
        let on = Set(online.map(\.path))
        let ruled = Set(model.appRoutes.keys).union(model.connectionRules.compactMap(\.app))
        return ruled.sorted().filter { !on.contains($0) }.map { AppInfo(path: $0, name: AppPath.displayName($0), uses: 0) }.filter { matches($0.name) }
    }
    private var others: [AppInfo] {
        let shown = Set(online.map(\.path) + withRules.map(\.path))
        return model.installedApps.filter { !shown.contains($0.path) && matches($0.name) }
    }

    var body: some View {
        Page {
            PageHeader(screen: .apps)
            if !model.tunnelRunning {
                Panel {
                    Row(title: "Нужен режим «Все приложения»", subtitle: "Правила для приложений действуют, когда он включён.") {
                        IconTile(symbol: "info", color: .wpVPN)
                    } trailing: {
                        if model.tunnelInstalled { Button("Включить") { model.setTunnel(true) }.rowControl(prominent: true) }
                        else { Button("Установить") { model.installDaemon() }.rowControl(prominent: true) }
                    }
                }
            }
            SearchField(prompt: "Поиск приложения", text: $query)
            section("В сети сейчас", online)
            section("С вашими правилами", withRules)
            section("Все приложения", others)
        }
        .sheet(item: $detail) { AppDetailSheet(app: $0).environment(model) }
    }

    @ViewBuilder private func section(_ title: String, _ list: [AppInfo]) -> some View {
        if !list.isEmpty {
            Panel(title: title) {
                ForEach(list.indexed(by: \.path)) { item in
                    if item.index > 0 { RowSeparator() }
                    AppRow(app: item.value) { detail = item.value }
                }
            }
        }
    }
}

struct AppRow: View {
    @Environment(AppModel.self) private var model
    let app: AppInfo
    var openDetail: () -> Void = {}

    var body: some View {
        let key = AppPath.canonical(app.path)
        let b = model.traffic.byApp[key]
        let target = model.target(app: key, site: nil)
        let exceptions = model.siteExceptions(for: key).count
        Row(title: app.name, subtitle: subtitle(b, target, exceptions), dot: model.targetColor(target)) {
            AppIcon(path: app.path)
        } trailing: {
            TargetMenu(current: target) { model.setTarget(app: key, site: nil, $0) }
            Button(action: openDetail) { Image(systemName: exceptions > 0 ? "slider.horizontal.3" : "ellipsis.circle").font(.system(size: 15)).foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Настроить по сайтам")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: openDetail)
    }

    private func subtitle(_ b: TrafficStats.Bucket?, _ target: ConnectionTarget?, _ exceptions: Int) -> String? {
        var parts: [String] = []
        if let target { parts.append("Всегда: \(model.targetTitle(target).lowercased())") }
        if exceptions > 0 { parts.append(plural(exceptions, "исключение", "исключения", "исключений")) }
        if let b, b.total > 0 { parts.append("VPN \(Fmt.bytes(b.vpn)) · напрямую \(Fmt.bytes(b.direct))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
