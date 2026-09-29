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
                    }
                    Spacer()
                    if !model.upstreamOK { Button("Подключить") { Task { await model.ensureVPN() } }.rowControl(prominent: true).disabled(model.vpnBusy) }
                }
            }

            if let host = model.currentHost {
                module {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Сайт в браузере").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let d = model.currentDecision { RouteBadge(route: d.action == .race ? "direct" : d.action.rawValue) }
                        }
                        Text(host).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        RoutePicker(selection: Binding(get: { model.currentIsPinned }, set: { model.pin(host, $0) })).frame(maxWidth: .infinity)
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
        .frame(width: 320)
        .onAppear { model.visible = true; model.refreshCurrentSite(); model.refreshExitCountry(); Task { await model.refresh() } }
        .onDisappear { model.visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshCurrentSite(); Task { await model.refresh() } }
    }

    private func module<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { c() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(radius: 16)
    }
}
