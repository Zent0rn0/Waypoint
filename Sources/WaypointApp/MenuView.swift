import SwiftUI
import WaypointCore

/// Menu bar popover built from Control Center-style modules.
struct MenuView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let h = model.hero
        VStack(spacing: 8) {
            module {
                HStack(spacing: 12) {
                    Circle().fill(LinearGradient(colors: h.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 38, height: 38)
                        .overlay(Image(systemName: h.symbol).font(.system(size: 17, weight: .bold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title).font(.headline)
                        Text(model.tunnelInstalled ? "Все приложения" : "Только браузеры").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if model.tunnelInstalled {
                        Toggle("", isOn: Binding(get: { model.tunnelWanted }, set: { model.setTunnel($0) })).toggleStyle(.switch).labelsHidden()
                    }
                }
                if let a = h.action {
                    Button(a.label, action: a.run).barControl(prominent: true).tint(h.color == .gray ? .accentColor : h.color)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).disabled(model.daemonBusy || model.vpnBusy)
                }
            }

            module {
                HStack(spacing: 10) {
                    if let p = model.vpnAppPath { AppIcon(path: p, size: 26) } else { IconTile(symbol: "lock.shield.fill", color: .wpVPN, size: 26) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.settings.vpnServiceName ?? "VPN")
                        StatusLine(text: model.upstreamOK ? "Подключено" + (model.exitVPN.map { " · \(AppModel.flag($0)) \(AppModel.countryName($0))" } ?? "") : "Не подключено",
                                   dot: model.upstreamOK ? .wpGood : .wpBad)
                        if let s = servingNow { StatusLine(text: "Сейчас обслуживает: \(s)") }
                    }
                    Spacer()
                    if !model.upstreamOK { Button("Подключить") { Task { await model.ensureVPN() } }.rowControl(prominent: true).disabled(model.vpnBusy) }
                }
            }

            module {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Сейчас в сети").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.tunnelRunning {
                            let t = model.traffic.total
                            Text("напрямую \(Fmt.bytes(t.direct)) · VPN \(Fmt.bytes(t.vpn))").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                    if !model.tunnelRunning {
                        Text("Список появится, когда включён режим «Все приложения».").font(.callout).foregroundStyle(.secondary)
                    } else if topApps.isEmpty {
                        Text("Пока ничего не передаётся.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(topApps, id: \.key) { app in appRow(app.key, app.value) }
                    }
                }
            }

            module {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Последние сайты").font(.caption).foregroundStyle(.secondary)
                    if recentSites.isEmpty {
                        Text("Когда вы откроете незнакомый сайт, он появится здесь с выбранным путём.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(recentSites, id: \.id) { e in siteRow(e) }
                    }
                }
            }

            if let t = model.toast { Text(t).font(.caption).foregroundStyle(Color.wpWarn).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4) }

            HStack {
                Button { MainWindow.shared.show(model: model) } label: { Label("Открыть Waypoint…", systemImage: "macwindow") }.buttonStyle(.borderless)
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.top, 2)
        }
        .glassGroup()
        .padding(10)
        .frame(width: 360)
        .onAppear { model.visible = true; model.refreshCurrentSite(); model.refreshExitCountry(); Task { await model.refresh() } }
        .onDisappear { model.visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshCurrentSite(); Task { await model.refresh() } }
    }

    // MARK: pieces

    private static let plumbing = ["/usr/libexec/", "/usr/sbin/", "/sbin/", "/System/", "/usr/bin/", "/Library/Apple/"]

    /// The applications that moved the most data this session (system plumbing left out).
    private var topApps: [(key: String, value: TrafficStats.Bucket)] {
        Array(model.traffic.byApp
            .filter { k, _ in k != "system" && AppPath.isValid(k) && !Self.plumbing.contains(where: k.hasPrefix) }
            .sorted { $0.value.total > $1.value.total }.prefix(4))
    }

    private func appRow(_ key: String, _ b: TrafficStats.Bucket) -> some View {
        let target = model.target(app: key, site: nil)
        let vpn = b.vpn >= b.direct
        return HStack(spacing: 9) {
            AppIcon(path: key, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppPath.displayName(key)).lineLimit(1)
                Text("VPN \(Fmt.bytes(b.vpn)) · напрямую \(Fmt.bytes(b.direct))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if target == nil { Pill(text: vpn ? "VPN" : "Напрямую", color: vpn ? .wpVPN : .wpDirect) }
            TargetMenu(current: target) { model.setTarget(app: key, site: nil, $0) }
        }
    }

    /// The latest checked sites, one line per site (not per request).
    private var recentSites: [RouteEvent] {
        var seen = Set<String>(), out: [RouteEvent] = []
        for e in model.events {
            let site = isIPLiteral(e.host) ? e.host : registrableDomain(e.host)
            if seen.insert(site).inserted { out.append(e) }
            if out.count == 5 { break }
        }
        return out
    }

    private func siteRow(_ e: RouteEvent) -> some View {
        let site = isIPLiteral(e.host) ? e.host : registrableDomain(e.host)
        let why: String
        switch e.source {
        case "manual": why = "ваше правило или сценарий"
        case "learned": why = "выучено раньше"
        case "starter": why = "встроенная подсказка"
        case "local": why = "локальная сеть"
        default: why = "проверка: \(e.ms) мс"
        }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(site).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text(why).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            RouteBadge(route: e.route)
            if !isIPLiteral(e.host) { TargetMenu(current: model.target(app: nil, site: site)) { model.setTarget(app: nil, site: site, $0) } }
        }
    }

    /// Which server the general pool is using right now.
    private var servingNow: String? {
        guard model.tunnelRunning, let tag = model.pools[.general]?.now else { return nil }
        if tag == "via-happ" { return model.settings.vpnServiceName ?? "VPN-клиент" }
        return ServerStore.outbounds(model.servers).first { $0.tag == tag }?.entry.name
    }

    private func module<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { c() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(radius: 16)
    }
}
