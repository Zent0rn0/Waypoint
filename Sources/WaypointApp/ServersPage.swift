import SwiftUI
import AppKit
import WaypointCore

/// Flag emoji at the start of a server name («🇩🇪 Германия») → (flag, rest).
enum ServerName {
    static func split(_ name: String) -> (flag: String?, title: String) {
        let sc = Array(name.unicodeScalars)
        func isRegional(_ u: Unicode.Scalar) -> Bool { (0x1F1E6...0x1F1FF).contains(u.value) }
        for i in 0..<max(0, sc.count - 1) where isRegional(sc[i]) && isRegional(sc[i + 1]) {
            let flag = String(String.UnicodeScalarView([sc[i], sc[i + 1]]))
            let rest = name.replacingOccurrences(of: flag, with: "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "|-·")))
            return (flag, rest.isEmpty ? name : rest)
        }
        return (nil, name)
    }
}

struct ServersPage: View {
    @Environment(AppModel.self) private var model
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        Page {
            PageHeader(screen: .servers)

            Panel(title: "Добавить", footer: "Ссылка подписки от провайдера (https://…) — в том числе ссылка импорта из Happ, v2rayN, sing-box, Clash или Hiddify. Или ссылка на один сервер: vless://, trojan://, ss://, hysteria2://, vmess:// или https:// для HTTPS-прокси.") {
                HStack(spacing: 8) {
                    TextField("Ссылка подписки или сервера", text: $link).fieldBox().onSubmit(add)
                    Button("Вставить") {
                        link = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        add()
                    }
                    .barControl()
                    Button("Добавить", action: add).barControl(prominent: true).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Metrics.rowInset)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Color.wpBad).fixedSize(horizontal: false, vertical: true) }

            Panel(title: "VPN-клиент", footer: "Своими серверами клиент распоряжается сам: Waypoint не читает его настройки и не расшифровывает его ссылки. Клиент всегда остаётся одним из вариантов выбора.") {
                Row(title: model.settings.vpnServiceName ?? "Не выбран", subtitle: model.upstreamOK ? "Подключено" : "Не подключено",
                    dot: model.upstreamOK ? .wpGood : .wpBad) {
                    if let p = model.vpnAppPath { AppIcon(path: p) } else { IconTile(symbol: "lock.shield.fill", color: .wpVPN) }
                } trailing: {
                    if !model.upstreamOK { Button(model.vpnBusy ? "Подключаю…" : "Подключить") { Task { await model.ensureVPN() } }.rowControl(prominent: true).disabled(model.vpnBusy) }
                }
            }

            if !model.subscriptions.isEmpty {
                Panel(title: "Подписки", footer: "Обновляются сами — по умолчанию каждый час (можно изменить в «Настройках»). Ваши включения и выключения серверов при обновлении сохраняются.") {
                    ForEach(model.subscriptions.indexed(by: \.id)) { item in
                        if item.index > 0 { RowSeparator() }
                        SubscriptionRow(sub: item.value)
                    }
                }
            }

            serverGroup(title: "Добавлены вручную", list: model.servers.filter { $0.source == nil }, footer: nil)
            ForEach(model.subscriptions) { sub in
                serverGroup(title: sub.name, list: model.servers.filter { $0.source == sub.id },
                            footer: model.settings.region == .russia ? "Серверы в России выключены по умолчанию: заблокированное через них не откроется, а TikTok увидит российский регион. Включено автоматически не больше \(Subscription.defaultEnabledLimit) — каждый включённый сервер регулярно проверяется." : nil)
            }

            if model.servers.contains(where: \.enabled) {
                Panel(title: "Кто сейчас обслуживает", footer: "Выбор пересматривается каждые 2 минуты по задержке до типичного сайта каждого вида трафика.") {
                    ForEach(PoolClass.allCases.indexed(by: \.self)) { item in
                        if item.index > 0 { RowSeparator() }
                        let c = item.value, p = model.pools[c]
                        Row(title: c.title, subtitle: p.map { "лучший из \($0.members.count)" } ?? (model.tunnelRunning ? "ждём первых измерений" : "работает, когда включены «Все приложения»")) {
                            IconTile(symbol: symbol(c), color: color(c))
                        } trailing: {
                            if let p { Text(name(p.now)).foregroundStyle(.secondary); if let d = p.delays[p.now] { Text("\(d) мс").foregroundStyle(.tertiary).monospacedDigit() } }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func serverGroup(title: String, list: [ServerEntry], footer: String?) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(title).font(.headline)
                    Text("· включено \(list.filter(\.enabled).count) из \(list.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button(model.auditRunning ? "Проверяю…" : "Проверить серверы") { Task { await model.auditServers(ids: Set(list.map(\.id))) } }
                        .rowControl().disabled(model.auditRunning)
                        .help("Работает ли каждый сервер, его задержка и страна, которую видят сайты")
                }
                .padding(.horizontal, 4)
                Panel(footer: footer) {
                    ForEach(list.indexed(by: \.id)) { item in
                        if item.index > 0 { RowSeparator() }
                        ServerRow(server: item.value)
                    }
                }
            }
        }
    }

    private func add() {
        error = model.addSource(link)
        if error == nil { link = "" }
    }
    private func name(_ tag: String) -> String {
        tag == "via-happ" ? (model.settings.vpnServiceName ?? "VPN-клиент") : (ServerStore.outbounds(model.servers).first { $0.tag == tag }?.entry.name ?? tag)
    }
    private func symbol(_ c: PoolClass) -> String { switch c { case .general: "globe"; case .video: "play.rectangle.fill"; case .ai: "sparkles"; case .chat: "phone.fill" } }
    private func color(_ c: PoolClass) -> Color { switch c { case .general: .blue; case .video: .red; case .ai: .purple; case .chat: .teal } }
}

struct SubscriptionRow: View {
    @Environment(AppModel.self) private var model
    let sub: SubscriptionEntry

    var body: some View {
        let busy = model.subscriptionBusy.contains(sub.id)
        Row(title: sub.name, subtitle: subtitle(busy), dot: busy ? .wpWarn : (sub.error == nil ? .wpGood : .wpBad)) {
            IconTile(symbol: "arrow.triangle.2.circlepath", color: .blue)
        } trailing: {
            if busy { ProgressView().controlSize(.small) }
            else { Button("Обновить") { Task { await model.refreshSubscription(sub.id) } }.rowControl() }
            InfoButton(title: sub.name, text: details)
            Button { model.removeSubscription(sub.id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Удалить подписку и её серверы")
        }
    }

    private func subtitle(_ busy: Bool) -> String {
        if busy { return "Обновляю…" }
        if let e = sub.error { return "Не обновилась: \(e)" }
        var parts = [plural(sub.servers, "сервер", "сервера", "серверов")]
        if let u = sub.updated { parts.append("обновлена \(Fmt.day.string(from: u))") }
        if let i = sub.info {
            if let t = i.total, t > 0 { parts.append("\(Fmt.bytes(i.used)) из \(Fmt.bytes(t))") } else if i.used > 0 { parts.append("израсходовано \(Fmt.bytes(i.used))") }
            if let x = i.expire { parts.append(x < Date() ? "срок истёк" : "до \(x.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))))") }
        }
        return parts.joined(separator: " · ")
    }

    private var details: String {
        var t = "Адрес: \(URL(string: sub.url)?.host ?? "—") (сама ссылка не показывается: в ней ваш личный ключ)."
        if sub.skipped > 0 {
            t += "\n\nНе добавлено серверов: \(sub.skipped). Причины:\n" + (sub.skippedReasons ?? []).prefix(5).map { "• \($0)" }.joined(separator: "\n")
            t += "\n\nНапример, транспорт xhttp есть только в Xray — такие серверы открывайте в самом VPN-клиенте."
        }
        return t
    }
}

struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let server: ServerEntry

    var body: some View {
        let parsed = try? ShareLink.parse(server.link)
        let (flag, title) = ServerName.split(server.name)
        let russian = model.settings.region == .russia && Subscription.looksRussian(server.name)
        Row(title: title, subtitle: subtitle(parsed, russian), dot: server.works == false ? .wpBad : (server.enabled ? .wpGood : .gray)) {
            if let flag { EmojiTile(emoji: flag) } else { IconTile(symbol: "server.rack", color: .indigo) }
        } trailing: {
            if let ms = model.serverDelays[server.id] ?? server.ms { Text("\(ms) мс").foregroundStyle(ms < 150 ? Color.wpGood : (ms < 400 ? Color.wpWarn : Color.wpBad)).monospacedDigit() }
            else if model.serverDelayFailed.contains(server.id) { Text("нет ответа").foregroundStyle(Color.wpBad) }
            Toggle("", isOn: Binding(get: { server.enabled }, set: { _ in model.toggleServer(server.id) })).toggleStyle(.switch).controlSize(.small).labelsHidden()
            if server.source == nil {
                Button { model.removeServer(server.id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless)
            }
        }
    }

    private func subtitle(_ p: ParsedServer?, _ russian: Bool) -> String {
        let proto = p?.proto.uppercased() ?? (try? XrayLink.parse(server.link)).map { $0.proto.uppercased() } ?? "?"
        var parts = [proto]
        if server.engine == "xray" { parts.append("через Xray") }
        if let w = server.works {
            if w { parts.append("выход \(server.exit.map { Diagnostics.country($0) } ?? "?")") }
            else { parts.append(ServerHealth.isAutoOff(server) ? "не отвечал, проверю снова сам" : "не отвечает") }
            if w, (server.fails ?? 0) > 0 { parts.append("был сбой при проверке") }
        } else if russian { parts.append("в России") }
        return parts.joined(separator: " · ")
    }
}
