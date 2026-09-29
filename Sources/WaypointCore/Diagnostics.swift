import Foundation
import Network

public struct DiagCheck: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable { case ok, warn, fail, skip, running }
    public enum Fix: String, Sendable { case startVPN, installDaemon, enableTunnel, openApp, none }
    public let id: String
    public var title: String
    public var status: Status
    public var detail: String
    public var hint: String?
    public var fix: Fix
    public init(id: String, title: String, status: Status, detail: String, hint: String? = nil, fix: Fix = .none) {
        self.id = id; self.title = title; self.status = status; self.detail = detail; self.hint = hint; self.fix = fix
    }
}

/// "Check every connection": walks the whole chain from the physical link to what each service actually sees,
/// and says what to do about anything that is off. Read-only: it never changes settings or routes.
public enum Diagnostics {
    public static let tiktokRegionRegex = #""(?:region|regionCode|appRegion)"\s*:\s*"([A-Za-z]{2})""#

    /// Two-letter region codes TikTok embeds in its page, e.g. ["CZ"]. Empty for stub pages.
    public static func tiktokRegions(in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: tiktokRegionRegex) else { return [] }
        let ns = html as NSString
        let all = re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)).uppercased() }
        return Array(Set(all)).sorted()
    }

    public static func country(_ code: String?) -> String {
        guard let code, code.count == 2 else { return "?" }
        let flag = String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
        return "\(flag) \(Locale(identifier: "ru_RU").localizedString(forRegionCode: code) ?? code)"
    }

    /// `loc=XX` from Cloudflare's trace endpoint: the country a service behind Cloudflare sees for this path.
    public static func cloudflareLoc(_ text: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix("loc=") }.map { String($0.dropFirst(4)) }
    }

    public static func run(engine: Engine, tunnel: TunnelStatus? = TunnelStatus.read(), extra: [DiagCheck] = [],
                           progress: @Sendable (DiagCheck) -> Void = { _ in }) async -> [DiagCheck] {
        var out: [DiagCheck] = []
        func add(_ c: DiagCheck) { out.append(c); progress(c) }
        let s = engine.settings
        let phys = engine.network.physical
        let socks: Probe.Path = .socks(host: s.upstreamHost, port: s.upstreamPort)

        // 1. physical link + DNS
        if let phys {
            switch await Probe.tlsHandshake(host: "example.com", path: .direct(phys), timeoutMs: 6000) {
            case .success(let ms): add(.init(id: "net", title: "Интернет", status: .ok, detail: "Работает напрямую через \(phys.name), ответ за \(ms) мс"))
            case .failure(let e): add(.init(id: "net", title: "Интернет", status: .fail, detail: "Нет ответа через \(phys.name) (\(e))", hint: "Проверьте Wi‑Fi или кабель."))
            }
        } else {
            add(.init(id: "net", title: "Интернет", status: .fail, detail: "Нет активного Wi‑Fi или Ethernet", hint: "Подключитесь к сети."))
        }

        // 2. VPN client
        let svc = s.vpnServiceName.flatMap { VPNController.service(named: $0) }
        if let svc, svc.isConnected {
            add(.init(id: "vpn", title: "VPN-клиент", status: .ok, detail: "\(svc.name) подключён"))
        } else if let name = s.vpnServiceName {
            add(.init(id: "vpn", title: "VPN-клиент", status: .fail, detail: "\(name): \(svc?.state ?? "не найден")", hint: "Заблокированное не откроется, пока VPN выключен.", fix: .startVPN))
        } else {
            add(.init(id: "vpn", title: "VPN-клиент", status: .warn, detail: "системный VPN-сервис не выбран", hint: "Выберите его в настройках."))
        }
        let socksOK = await UpstreamProbe.isOpenSocks5(host: s.upstreamHost, port: s.upstreamPort, timeoutMs: 1200)
        add(.init(id: "socks", title: "Связь с VPN-клиентом", status: socksOK ? .ok : .fail,
                  detail: socksOK ? "Локальный порт \(s.upstreamPort) отвечает" : "Локальный порт \(s.upstreamPort) не отвечает",
                  hint: socksOK ? nil : "Включите VPN-клиент или укажите его порт в настройках.", fix: socksOK ? .none : .startVPN))

        // 3. does the VPN really change what services see?
        if socksOK {
            async let d = Probe.httpsGet(host: "www.cloudflare.com", path: "/cdn-cgi/trace", via: .direct(phys), timeoutMs: 8000)
            async let v = Probe.httpsGet(host: "www.cloudflare.com", path: "/cdn-cgi/trace", via: socks, timeoutMs: 8000)
            let (dr, vr) = await (d, v)
            let dl = (try? dr.get()).flatMap { cloudflareLoc($0.text) }, vl = (try? vr.get()).flatMap { cloudflareLoc($0.text) }
            if let vl {
                let differs = dl != nil && dl != vl
                add(.init(id: "egress", title: "Страна выхода", status: differs ? .ok : .warn,
                          detail: "Напрямую: \(Self.country(dl)) · через VPN: \(Self.country(vl))" + (differs ? "" : " — совпадает"),
                          hint: differs ? nil : "Если страны одинаковые, VPN-сервер в той же стране, что и вы, или трафик не идёт через VPN."))
            } else {
                add(.init(id: "egress", title: "Страна выхода", status: .fail, detail: "через VPN проверить не удалось", hint: "Канал VPN не пропускает трафик."))
            }
        } else {
            add(.init(id: "egress", title: "Страна выхода", status: .skip, detail: "нет канала VPN"))
        }

        // 4. Waypoint's own pieces
        let racer = await Probe.tcpOpen(host: "127.0.0.1", port: s.listenPort)
        add(.init(id: "racer", title: "Служба Waypoint", status: racer ? .ok : .fail,
                  detail: racer ? "Работает" : "Не отвечает (порт \(s.listenPort))", hint: racer ? nil : "Запустите Waypoint."))

        // 5. tunnel daemon
        if let t = tunnel {
            let fresh = Date().timeIntervalSince(t.updated) < 30 || t.state == .off
            switch t.state {
            case .running: add(.init(id: "daemon", title: "Системный компонент", status: fresh ? .ok : .warn, detail: t.message + (t.servers.map { $0 > 0 ? "; своих серверов: \($0)" : "" } ?? "")))
            case .off: add(.init(id: "daemon", title: "Системный компонент", status: .ok, detail: "Установлен, режим «Все приложения» выключен", hint: "Включите его, чтобы охватить все приложения.", fix: .enableTunnel))
            case .waiting, .starting: add(.init(id: "daemon", title: "Системный компонент", status: .warn, detail: t.message))
            case .error: add(.init(id: "daemon", title: "Системный компонент", status: .fail, detail: t.message, hint: "Сеть при этом работает как обычно."))
            }
            for n in t.notes ?? [] { add(.init(id: "note-\(n.hashValue)", title: "Замечание компонента", status: .warn, detail: n)) }
        } else {
            add(.init(id: "daemon", title: "Системный компонент", status: .warn, detail: "Не установлен",
                      hint: "Без него работают только браузеры и приложения с поддержкой прокси.", fix: .installDaemon))
        }

        // 6. tunnel actually routing? (default route for an arbitrary address must go into our TUN)
        let tunnelUp = tunnel?.state == .running
        if tunnelUp {
            let r = runProcess("/sbin/route", ["-n", "get", "1.1.1.1"]).out
            let iface = r.split(separator: "\n").first { $0.contains("interface:") }.map { $0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces) }
            let ours = iface != nil && iface != phys?.name && iface != tunnel?.vpn
            add(.init(id: "route", title: "Весь трафик через Waypoint", status: ours ? .ok : .warn, detail: ours ? "Соединения системы проходят через Waypoint (\(iface ?? "?"))" : "Трафик идёт мимо Waypoint (\(iface ?? "?"))"))
        }

        // 7. live API
        if tunnelUp, let api = ClashClient() {
            if let snap = try? await api.connections() {
                add(.init(id: "api", title: "Активность", status: .ok, detail: "Активных соединений: \(snap.connections.count)"))
            } else { add(.init(id: "api", title: "Активность", status: .warn, detail: "Список соединений недоступен")) }
        }

        // 8. routing matrix: for each sample, the path Waypoint decides must actually work
        let samples: [(String, String)] = [("yandex.ru", "напрямую"), ("www.gosuslugi.ru", "напрямую"), ("www.youtube.com", "VPN"),
                                          ("www.instagram.com", "VPN"), ("discord.com", "VPN"), ("web.telegram.org", "VPN"), ("github.com", "авто")]
        var lines: [String] = [], bad = 0
        for (h, label) in samples {
            let d = engine.rules.decide(host: h, port: 443)
            let cmp = await Probe.compare(host: h, interface: phys, upstream: socksOK ? (s.upstreamHost, s.upstreamPort) : nil)
            let directOK: Bool = { if case .success = cmp.direct { return true }; return false }()
            let vpnOK: Bool = { if case .success? = cmp.vpn { return true }; return false }()
            let want = d.action == .vpn ? "VPN" : "напрямую"
            let works = d.action == .vpn ? vpnOK : (d.action == .direct ? directOK : (directOK || vpnOK))
            if !works { bad += 1 }
            lines.append("\(works ? "✓" : "✗") \(h) — \(d.action == .race ? "проверка при заходе" : want.lowercased()) · напрямую \(directOK ? "открывается" : "не открывается")")
        }
        add(.init(id: "matrix", title: "Популярные сайты", status: bad == 0 ? .ok : .fail, detail: lines.joined(separator: "\n"),
                  hint: bad == 0 ? nil : "✗ — выбранный путь не работает: проверьте VPN или правило для сайта."))

        // 9. TikTok: every path, and the region the site really sees
        add(await tiktok(engine: engine, socks: socks, socksOK: socksOK, tunnelUp: tunnelUp))

        // 10. Telegram / Discord routing
        let tg = engine.rules.decide(host: "149.154.167.35", port: 443)
        add(.init(id: "telegram", title: "Telegram", status: tg.action == .vpn ? .ok : .warn,
                  detail: "Серверы Telegram — \(tg.action == .vpn ? "через VPN" : "напрямую")",
                  hint: tg.action == .vpn ? nil : "Включите стартовые списки (регион «Россия») или сценарий «Голос, звонки и игры»."))
        let dc = engine.rules.decide(host: "gateway.discord.gg", port: 443)
        let udp = engine.rules.currentPolicy.udpViaVPN
        add(.init(id: "discord", title: "Discord", status: dc.action == .vpn ? (udp ? .ok : .warn) : .warn,
                  detail: "Чат — \(dc.action == .vpn ? "через VPN" : "напрямую"), голос — \(udp ? "через VPN" : "напрямую")",
                  hint: udp ? nil : "Чтобы голос тоже шёл через VPN, включите сценарий «Голос, звонки и игры»."))

        for c in extra { add(c) }
        return out
    }

    /// TikTok is region-locked by the *address requests come from*: if any part leaves through a Russian ISP the feed stays old.
    static func tiktok(engine: Engine, socks: Probe.Path, socksOK: Bool, tunnelUp: Bool) async -> DiagCheck {
        let d = engine.rules.decide(host: "www.tiktok.com", port: 443)
        let decision = d.action == .vpn ? "VPN" : d.action == .direct ? "напрямую" : "авто"
        async let direct = Probe.httpsGet(host: "www.tiktok.com", via: .direct(engine.network.physical), timeoutMs: 12000)
        async let vpn: Result<Probe.HTTPResult, Error> = socksOK ? await Probe.httpsGet(host: "www.tiktok.com", via: socks, timeoutMs: 15000) : .failure(UpstreamError("нет VPN"))
        async let unpinned: Result<Probe.HTTPResult, Error> = tunnelUp ? await Probe.httpsGet(host: "www.tiktok.com", via: .direct(nil), timeoutMs: 15000) : .failure(UpstreamError("туннель выключен"))
        let (dr, vr, ur) = await (direct, vpn, unpinned)

        func describe(_ r: Result<Probe.HTTPResult, Error>) -> (String, [String], Bool) {
            guard case .success(let h) = r else { return ("нет ответа", [], false) }
            let regions = tiktokRegions(in: h.text)
            let real = h.body.count > 50_000
            return (real ? "полный сайт" : "заглушка (\(h.body.count) Б)", regions, real)
        }
        let (dt, dreg, _) = describe(dr), (vt, vreg, vReal) = describe(vr), (ut, ureg, uReal) = describe(ur)
        var lines = ["Waypoint отправляет TikTok: \(decision.lowercased())", "Напрямую: \(dt)" + (dreg.isEmpty ? "" : ", регион \(dreg.joined(separator: "/"))")]
        lines.append("Через VPN: \(vt)" + (vreg.isEmpty ? "" : ", регион \(vreg.joined(separator: "/"))"))
        if tunnelUp { lines.append("Как видит обычное приложение: \(ut)" + (ureg.isEmpty ? "" : ", регион \(ureg.joined(separator: "/"))")) }
        let vpnRegionOK = vReal && !vreg.contains("RU") && !vreg.isEmpty
        var status: DiagCheck.Status = .ok
        var hint: String?
        if !socksOK { status = .fail; hint = "Без VPN TikTok не покажет новую ленту." }
        else if !vpnRegionOK { status = .warn; hint = vReal ? "Сервер VPN в России или регион не определён — лента может быть старой. Смените сервер в клиенте VPN." : "TikTok не открылся через VPN." }
        else if d.action != .vpn { status = .warn; hint = "Включите сценарий «TikTok — свежая лента»: сейчас домены TikTok не принудительно идут через VPN." }
        else if tunnelUp && (!uReal || ureg.isEmpty || ureg.contains("RU")) { status = .warn; hint = "Через туннель TikTok видит регион \(ureg.isEmpty ? "не определён" : ureg.joined(separator: "/")) — часть запросов уходит мимо VPN." }
        else {
            lines.append("Итог: регион \((tunnelUp ? ureg : vreg).joined(separator: "/")) — не Россия, лента будет свежей")
            // Balancing VPN clients exit from a different country per connection. That is not a leak, but TikTok may notice.
            if tunnelUp, !ureg.isEmpty, ureg != vreg { hint = "Страна выхода меняется между соединениями (\(vreg.joined(separator: "/")) и \(ureg.joined(separator: "/"))): клиент балансирует серверы. Если лента «прыгает», закрепите один сервер в клиенте VPN." }
        }
        return .init(id: "tiktok", title: "TikTok", status: status, detail: lines.joined(separator: "\n"), hint: hint)
    }
}
