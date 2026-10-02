import SwiftUI
import WaypointCore

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    let w = (n10 == 1 && n100 != 11) ? one : ((2...4).contains(n10) && !(12...14).contains(n100) ? few : many)
    return "\(n) \(w)"
}

// MARK: - The one status of the app

struct HeroState {
    var title: String
    var detail: String
    var color: Color
    var gradient: [Color]
    var symbol: String
    var action: (label: String, run: () -> Void)?
}

extension AppModel {
    var hero: HeroState {
        let good = [Color(red: 0.16, green: 0.72, blue: 0.40), Color(red: 0.07, green: 0.60, blue: 0.62)]
        let warn = [Color(red: 1.00, green: 0.62, blue: 0.04), Color(red: 0.98, green: 0.40, blue: 0.20)]
        let bad = [Color(red: 1.00, green: 0.33, blue: 0.28), Color(red: 0.82, green: 0.14, blue: 0.32)]
        let info = [Color(red: 0.04, green: 0.52, blue: 1.00), Color(red: 0.38, green: 0.35, blue: 0.92)]
        let off = [Color(white: 0.52), Color(white: 0.36)]
        if let e = startError {
            return HeroState(title: "Не удалось запуститься", detail: e, color: .wpBad, gradient: bad, symbol: "exclamationmark.octagon.fill")
        }
        if !upstreamOK && settings.vpnServiceName != nil {
            return HeroState(title: "VPN не подключён", detail: "Заблокированные сайты не откроются. Остальное работает как обычно.",
                             color: .wpBad, gradient: bad, symbol: "bolt.horizontal.fill", action: ("Подключить VPN", { Task { await self.ensureVPN() } }))
        }
        if tunnel?.state == .error {
            return HeroState(title: "Пауза после сбоя", detail: "Интернет работает как обычно, Waypoint повторит попытку сам.",
                             color: .wpWarn, gradient: warn, symbol: "exclamationmark.triangle.fill",
                             action: ("Повторить сейчас", { self.setTunnel(false); Task { try? await Task.sleep(nanoseconds: 1_500_000_000); self.setTunnel(true) } }))
        }
        if tunnel?.state == .running {
            return HeroState(title: "Всё работает", detail: "Заблокированное идёт через VPN, остальное — напрямую. Для каждого приложения.",
                             color: .wpGood, gradient: good, symbol: "checkmark")
        }
        if tunnelWanted {
            return HeroState(title: "Запускается…", detail: tunnel?.message ?? "Несколько секунд.", color: .wpWarn, gradient: warn, symbol: "hourglass")
        }
        if !tunnelInstalled {
            return HeroState(title: "Работает в браузерах", detail: "Чтобы охватить все приложения — Telegram, Discord, игры, — нужен системный компонент.",
                             color: .wpVPN, gradient: info, symbol: "globe", action: ("Установить", { self.installDaemon() }))
        }
        return HeroState(title: "Выключено", detail: "Включите «Все приложения», и Waypoint будет выбирать путь для каждого соединения.",
                         color: .gray, gradient: off, symbol: "power")
    }
}

// MARK: - Overview

struct OverviewPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            HeroCard()
            SetupCard()
            StatusTiles()
            SessionPanel()
        }
        .onAppear { model.refreshExitCountry() }
    }
}

/// The state of the app, on calm glass: the color lives in the round badge only (a fully green card on a green window
/// was too much). It carries the one switch that matters.
struct HeroCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let h = model.hero
        HStack(alignment: .center, spacing: 18) {
            Circle().fill(h.color.gradient).frame(width: 58, height: 58)
                .overlay(Image(systemName: h.symbol).font(.system(size: 26, weight: .bold)).foregroundStyle(.white))
                .shadow(color: h.color.opacity(0.35), radius: 10, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(h.title).font(.system(size: 24, weight: .bold))
                Text(h.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let a = h.action {
                    Button(a.label, action: a.run).barControl(prominent: true).tint(h.color == .gray ? .accentColor : h.color).padding(.top, 6)
                        .disabled(model.daemonBusy || model.vpnBusy)
                }
            }
            Spacer(minLength: 12)
            if model.tunnelInstalled {
                VStack(spacing: 6) {
                    Toggle("Все приложения", isOn: Binding(get: { model.tunnelWanted }, set: { model.setTunnel($0) }))
                        .toggleStyle(.switch).labelsHidden()
                    Text("Все приложения").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                .help("Режим «Все приложения»: Waypoint выбирает путь для каждого соединения системы")
            }
        }
        .padding(22)
        .glassSurface(radius: Metrics.cardRadius, tint: h.color.opacity(0.06))
    }
}

/// Home-style alert, only while something is left to set up.
struct SetupCard: View {
    @Environment(AppModel.self) private var model

    private struct Step: Identifiable { let id: String; let title: String; let label: String; let run: @MainActor () -> Void }

    private var steps: [Step] {
        let m = model
        var out: [Step] = []
        if !m.tunnelInstalled { out.append(Step(id: "d", title: "Системный компонент для всех приложений", label: "Установить", run: { m.installDaemon() })) }
        else if m.daemonOutdated { out.append(Step(id: "u", title: "Обновить системный компонент — нужен для правил соединений и серверов через Xray", label: "Обновить", run: { m.installDaemon() })) }
        if !m.launchAtLogin { out.append(Step(id: "l", title: "Открывать Waypoint при входе в систему", label: "Включить", run: { m.setLaunchAtLogin(true) })) }
        if m.communityInstalled.isEmpty { out.append(Step(id: "c", title: "Списки уже известных блокировок", label: "Скачать", run: { m.applySettings { $0.communityLists = true }; Task { await m.updateCommunityLists() } })) }
        return out
    }

    var body: some View {
        let list = steps
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(Color.wpWarn).frame(width: 28, height: 28)
                        .overlay(Image(systemName: "exclamationmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Завершите настройку").font(.headline)
                        Text("Осталось \(plural(list.count, "шаг", "шага", "шагов")) — каждый в один клик.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                ForEach(list) { st in
                    RowSeparator(inset: 54)
                    HStack {
                        Text(st.title)
                        Spacer()
                        Button(st.label) { st.run() }.rowControl(prominent: true)
                    }
                    .padding(.leading, 54).padding(.trailing, 14).frame(minHeight: 40)
                }
            }
            .groupBackground()
        }
    }
}

/// Home-style tiles: each summarizes one thing and leads to its page.
struct StatusTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = (model.settings.playbooks ?? []).count
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            StatusTile(title: model.settings.vpnServiceName ?? "VPN", status: model.upstreamOK ? "Подключён" : "Не подключён",
                       dot: model.upstreamOK ? .wpGood : .wpBad, action: { model.go(.servers) }) {
                if let p = model.vpnAppPath { AppIcon(path: p, size: 32) } else { IconTile(symbol: "lock.shield.fill", color: .wpVPN, size: 32) }
            }
            StatusTile(title: model.exitVPN.map { AppModel.countryName($0) } ?? "Страна", status: model.exitVPN == nil ? "проверяю…" : "выход в сеть",
                       dot: nil, action: { model.go(.diagnostics) }) {
                EmojiTile(emoji: AppModel.flag(model.exitVPN), size: 32)
            }
            StatusTile(title: "Сценарии", status: active == 0 ? "не включены" : "включено: \(active)", dot: nil, action: { model.go(.scenarios) }) {
                IconTile(symbol: Screen.scenarios.symbol, color: Screen.scenarios.color, size: 32)
            }
            StatusTile(title: "Выучено", status: plural(model.learned.count, "сайт", "сайта", "сайтов"), dot: nil, action: { model.go(.sites) }) {
                IconTile(symbol: "graduationcap.fill", color: .orange, size: 32)
            }
        }
    }
}

struct StatusTile<Icon: View>: View {
    let title: String
    let status: String
    var dot: Color?
    let action: () -> Void
    @ViewBuilder var icon: Icon
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    StatusLine(text: status, dot: dot).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(radius: Metrics.tileRadius, interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SessionPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.traffic
        let plumbing = ["/usr/libexec/", "/usr/sbin/", "/sbin/", "/System/", "/usr/bin/", "/Library/Apple/"]
        let top = t.byApp.filter { k, _ in k != "system" && !plumbing.contains(where: k.hasPrefix) }.sorted { $0.value.total > $1.value.total }.prefix(3)
        Panel(title: "За эту сессию") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    amount("Напрямую", t.total.direct, .wpDirect, .leading)
                    Spacer()
                    amount("Через VPN", t.total.vpn, .wpVPN, .trailing)
                }
                SplitBar(direct: t.total.direct, vpn: t.total.vpn)
                Text("Напрямую — быстрее и без траты трафика VPN. Через VPN идёт только то, что иначе не откроется.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Metrics.rowInset)
            RowSeparator(inset: Metrics.rowInset)
            LinkRow(title: "Больше всего трафика",
                    subtitle: top.isEmpty ? (model.tunnelRunning ? "Собираю данные…" : "Появится, когда включены «Все приложения»") : top.map { AppPath.displayName($0.key) }.joined(separator: " · "),
                    action: { model.go(.activity) }) {
                AppIcon(path: top.first?.key, size: Metrics.tile)
            }
        }
    }

    private func amount(_ label: String, _ bytes: UInt64, _ color: Color, _ align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 1) {
            HStack(spacing: 5) { Circle().fill(color).frame(width: 7, height: 7); Text(label).font(.caption).foregroundStyle(.secondary) }
            Text(Fmt.bytes(bytes)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}
