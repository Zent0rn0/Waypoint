import SwiftUI
import WaypointCore

/// The full «куда идёт» choice: auto, the three routes, the VPN client alone, or one exact server.
/// Same pop-up look as every other menu in rows.
struct TargetMenu: View {
    @Environment(AppModel.self) private var model
    let current: ConnectionTarget?
    var allowAuto = true
    var size: ControlSize = .small
    let set: (ConnectionTarget?) -> Void

    var body: some View {
        Menu {
            if allowAuto { item("Авто — Waypoint решит сам", nil); Divider() }
            item("Через VPN — лучший путь", .vpn)
            item("Напрямую", .direct)
            item("Блокировать", .block)
            Divider()
            item("Только через \(model.settings.vpnServiceName ?? "VPN-клиент")", .client)
            Menu("Через сервер") {
                let list = model.servers.filter { $0.enabled && $0.works != false }
                if list.isEmpty { Text("Нет включённых серверов") }
                ForEach(list) { s in
                    let (flag, title) = ServerName.split(s.name)
                    item([flag, title].compactMap { $0 }.joined(separator: " ") + (s.ms.map { " · \($0) мс" } ?? ""), .server(s.id))
                }
            }
        } label: {
            Text(model.targetTitle(current))
        }
        .menuStyle(.button).menuIndicator(.visible)
        .contentButton(prominent: false).controlSize(size).fixedSize()
        .help("Куда идут эти соединения")
    }

    private func item(_ title: String, _ t: ConnectionTarget?) -> some View {
        Toggle(title, isOn: Binding(get: { current == t }, set: { _ in set(t) }))
    }
}

/// Context-menu sections for one live connection: the whole app, the whole site, or only this app to this site.
struct ConnectionContextMenu: View {
    @Environment(AppModel.self) private var model
    let appPath: String?
    let appName: String
    let host: String

    var body: some View {
        let site = isIPLiteral(host) ? nil : registrableDomain(host)
        if let p = appPath, AppPath.isValid(p) {
            if let site {
                Menu("Только «\(appName)» → «\(site)»") { targets(app: p, site: site) }
            }
            Menu("Всё приложение «\(appName)»") { targets(app: p, site: nil) }
        }
        if let site { Menu("Сайт «\(site)» для всех") { targets(app: nil, site: site) } }
    }

    @ViewBuilder private func targets(app: String?, site: String?) -> some View {
        let cur = model.target(app: app, site: site)
        Toggle("Авто", isOn: Binding(get: { cur == nil }, set: { _ in model.setTarget(app: app, site: site, nil) }))
        Divider()
        ForEach([ConnectionTarget.vpn, .direct, .block, .client], id: \.self) { t in
            Toggle(model.targetTitle(t), isOn: Binding(get: { cur == t }, set: { _ in model.setTarget(app: app, site: site, t) }))
        }
        Menu("Через сервер") {
            ForEach(model.servers.filter { $0.enabled && $0.works != false }) { s in
                Toggle(model.targetTitle(.server(s.id)), isOn: Binding(get: { cur == .server(s.id) }, set: { _ in model.setTarget(app: app, site: site, .server(s.id)) }))
            }
        }
    }
}

/// One application in detail: its own path, per-site exceptions, and every host it has just talked to.
struct AppDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: AppInfo
    @State private var newSite = ""
    @State private var newTarget: ConnectionTarget = .direct

    private var key: String { AppPath.canonical(app.path) }

    /// Hosts from the live table for this app, busiest first.
    private struct Host { let host: String; let path: LiveConnection.Path; let bytes: UInt64 }
    private var recent: [Host] {
        var by: [String: Host] = [:]
        for c in model.connections where c.appPath.map(AppPath.canonical) == key && !c.host.isEmpty {
            let h = isIPLiteral(c.host) ? c.host : registrableDomain(c.host)
            by[h] = Host(host: h, path: c.path, bytes: (by[h]?.bytes ?? 0) + c.download + c.upload)
        }
        return Array(by.values.sorted { $0.bytes > $1.bytes }.prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIcon(path: app.path, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 20, weight: .bold))
                    Text(key).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Panel(title: "Всё приложение", footer: "Действует на все процессы приложения и все его адреса — кроме сайтов ниже.") {
                        Row(title: "Все соединения", subtitle: hint(model.target(app: key, site: nil))) {
                            IconTile(symbol: "app.connected.to.app.below.fill", color: .orange)
                        } trailing: {
                            TargetMenu(current: model.target(app: key, site: nil)) { model.setTarget(app: key, site: nil, $0) }
                        }
                    }

                    Panel(title: "Отдельные сайты", footer: "Исключение важнее правила для всего приложения и любых правил для сайта. Например: Discord целиком через VPN, а discord.com — через сервер в Германии.") {
                        ForEach(model.siteExceptions(for: key).indexed(by: \.id)) { item in
                            if item.index > 0 { RowSeparator() }
                            let r = item.value
                            Row(title: r.site!, subtitle: hint(r.target), dot: model.targetColor(r.target)) {
                                IconTile(symbol: "globe", color: model.targetColor(r.target) ?? .gray)
                            } trailing: {
                                TargetMenu(current: r.target, allowAuto: false) { model.setTarget(app: key, site: r.site, $0) }
                                Button { model.setTarget(app: key, site: r.site, nil) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.borderless).help("Убрать исключение")
                            }
                        }
                        if !model.siteExceptions(for: key).isEmpty { RowSeparator(inset: Metrics.rowInset) }
                        HStack(spacing: 8) {
                            TextField("Сайт, например discord.com", text: $newSite).fieldBox().onSubmit(add)
                            TargetMenu(current: newTarget, allowAuto: false, size: .regular) { if let t = $0 { newTarget = t } }
                            Button("Добавить", action: add).barControl(prominent: true).disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(Metrics.rowInset)
                    }

                    Panel(title: "Куда оно ходит сейчас", footer: recent.isEmpty ? nil : "Выберите путь для любого адреса — это станет исключением для этого приложения.") {
                        if recent.isEmpty {
                            Row(title: model.tunnelRunning ? "Сейчас не в сети" : "Видно, когда включены «Все приложения»",
                                subtitle: "Здесь появятся адреса, к которым приложение подключается") { IconTile(symbol: "network", color: .gray) }
                        }
                        ForEach(recent.indexed(by: \.host)) { item in
                            if item.index > 0 { RowSeparator() }
                            let h = item.value
                            Row(title: h.host, subtitle: "Сейчас: \(pathTitle(h.path)) · \(Fmt.bytes(h.bytes))", dot: pathColor(h.path)) {
                                IconTile(symbol: "arrow.up.arrow.down", color: pathColor(h.path))
                            } trailing: {
                                TargetMenu(current: model.target(app: key, site: h.host)) { model.setTarget(app: key, site: h.host, $0) }
                            }
                        }
                    }
                }
                .glassGroup()
            }
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Готово") { dismiss() }.barControl(prominent: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 620, height: 600)
    }

    private func add() {
        guard ConnectionRule.normalizeSite(newSite) != nil else { model.flash("Не похоже на адрес сайта"); return }
        model.setTarget(app: key, site: newSite, newTarget)
        newSite = ""
    }
    private func hint(_ t: ConnectionTarget?) -> String {
        switch t {
        case nil: "Авто — как решат сценарии, сервисы и обучение"
        case .server?: "Только через этот сервер"
        case .client?: "Только через VPN-клиент, без своих серверов"
        case .vpn?: "Через лучший из VPN-клиента и ваших серверов"
        case .direct?: "Мимо VPN"
        case .block?: "Соединения запрещены"
        }
    }
    private func pathTitle(_ p: LiveConnection.Path) -> String {
        switch p { case .direct: "напрямую"; case .vpn: "через VPN"; case .race: "проверка"; case .blocked: "заблокировано"; case .unknown: "—" }
    }
    private func pathColor(_ p: LiveConnection.Path) -> Color {
        switch p { case .direct: .wpDirect; case .vpn: .wpVPN; case .race: .wpWarn; default: .gray }
    }
}
