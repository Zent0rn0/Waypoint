import Foundation
import AppKit
import WaypointCore

// Small argument helpers -------------------------------------------------------------------------

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even when redirected to a file
let args = Array(CommandLine.arguments.dropFirst())
func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func usage() -> Never {
    print("""
    waypoint — умная маршрутизация: напрямую или через VPN, автоматически

    Команды:
      run [--port N] [--quiet]     запустить прокси (SOCKS5/HTTP + PAC) и показывать решения
      doctor [--full]              проверить окружение; --full — вся цепочка, маршруты по сайтам, TikTok, Telegram, Discord
      check <хост> [...]           открыть хост обоими путями и сказать, какой нужен
      why <хост>                   какое правило сработает для хоста
      learned [list|clear|forget <домен>]
      rules [list|add "<vpn|direct|block> <домен>"|remove "<строка>"]
      conn [list|add [--app <путь>] [--site <сайт>] <direct|vpn|client|block|server:<имя>>|remove <app|*> <site|*>]
                                   правила для отдельных соединений: приложение, сайт или пара «приложение → сайт»
      proxy on|off|status          применить/снять PAC в настройках сети macOS
      happ-sync [--activate] [--open]  профиль маршрутизации Happ из выученного (по умолчанию печатает ссылку)
      tunnel on|off|status|conns   режим туннеля для ВСЕХ приложений (нужен установленный демон, см. scripts/install-daemon.sh)
      servers audit                какие серверы работают, их задержка и страна выхода
      sub test <ссылка>            скачать подписку и показать серверы (ничего не сохраняет)
      vpn status|start|stop        управление VPN-клиентом (то же, что делает приложение при запуске)
      pac                          напечатать PAC-файл
    """)
    exit(2)
}

func ms(_ r: Result<Int, Error>) -> String {
    switch r {
    case .success(let t): return "OK \(t) мс"
    case .failure(let e):
        let s = "\(e)"
        return s.contains("imeout") ? "таймаут" : s.contains("reset") ? "RST" : String(s.prefix(40))
    }
}

func waitForSignals(_ onStop: @escaping () -> Void) -> Never {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { onStop() }
        src.resume()
        signalSources.append(src)
    }
    dispatchMain()
}
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

// Commands ---------------------------------------------------------------------------------------

guard let command = args.first else { usage() }
let engine = Engine()

switch command {

case "run":
    if let p = value(after: "--port").flatMap(UInt16.init) { engine.update { $0.listenPort = p } }
    let quiet = args.contains("--quiet")
    engine.onEvent = { e in
        guard !quiet else { return }
        let t = DateFormatter(); t.dateFormat = "HH:mm:ss"
        let route = e.route.uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)
        print("\(t.string(from: e.time))  \(route) \(e.host):\(e.port)  [\(e.source)] \(e.note)  \(e.ms) мс")
    }
    engine.onLearned = { l in print("★ выучено: \(l.domain) → VPN") }
    Task {
        do {
            try await engine.start()
            let s = engine.settings
            print("Waypoint слушает 127.0.0.1:\(s.listenPort)  ·  апстрим (VPN) \(s.upstreamHost):\(s.upstreamPort)  ·  регион: \(s.region.rawValue)")
            print("PAC: \(s.pacURL)")
        } catch {
            fputs("Не удалось запуститься: \(error)\n", stderr)
            exit(1)
        }
    }
    waitForSignals {
        engine.stop()
        let st = engine.stats
        print("\nВсего соединений: \(st.total), напрямую \(st.directBytes / 1024) КБ, через VPN \(st.vpnBytes / 1024) КБ")
        exit(0)
    }

case "doctor" where args.contains("--full"):
    Task {
        engine.network.start()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let icon: [DiagCheck.Status: String] = [.ok: "✅", .warn: "⚠️ ", .fail: "❌", .skip: "⏭ ", .running: "…"]
        let checks = await Diagnostics.run(engine: engine) { c in
            print("\(icon[c.status] ?? "?") \(c.title)")
            for l in c.detail.split(separator: "\n") { print("     \(l)") }
            if let h = c.hint { print("     → \(h)") }
        }
        let bad = checks.filter { $0.status == .fail }.count, warn = checks.filter { $0.status == .warn }.count
        print("\nИтого: \(checks.filter { $0.status == .ok }.count) в порядке, \(warn) предупреждений, \(bad) проблем")
        exit(bad == 0 ? 0 : 1)
    }
    dispatchMain()

case "doctor":
    Task {
        let s = engine.settings
        engine.network.start()
        try? await Task.sleep(nanoseconds: 600_000_000)
        print("— Сеть")
        print("  физический интерфейс: \(engine.network.physical?.name ?? "не найден")  (все: \(engine.network.allInterfaces.map(\.name).joined(separator: ", ")))")

        print("— VPN-сервисы системы")
        let services = VPNController.list()
        if services.isEmpty { print("  нет") }
        for v in services { print("  \(v.name): \(v.state)") }

        print("— Апстрим (локальный SOCKS5 вашего VPN-клиента)")
        var upstream: (String, UInt16)?
        if await UpstreamProbe.isOpenSocks5(host: s.upstreamHost, port: s.upstreamPort) {
            print("  \(s.upstreamHost):\(s.upstreamPort) — SOCKS5 без пароля: OK")
            upstream = (s.upstreamHost, s.upstreamPort)
        } else if let p = await UpstreamProbe.detect() {
            print("  \(s.upstreamHost):\(s.upstreamPort) недоступен, но найден SOCKS5 на порту \(p) → waypoint run будет использовать настройку upstreamPort=\(p)")
            engine.update { $0.upstreamPort = p }
            upstream = (s.upstreamHost, p)
        } else {
            print("  SOCKS5 не найден. Включите VPN-клиент (Happ) и проверьте, что он открывает локальный порт.")
        }

        print("— Пути к example.com (TLS-рукопожатие)")
        let c = await Probe.compare(host: "example.com", interface: engine.network.physical, upstream: upstream)
        print("  напрямую: \(ms(c.direct))    через VPN: \(c.vpn.map(ms) ?? "—")")

        print("— Системный прокси (PAC)")
        print("  сейчас: \(SystemProxy.effectivePACURL() ?? "не задан")")
        print("  наш:    \(s.pacURL)  \(SystemProxy.isApplied(s.pacURL) ? "← применён" : "(не применён; включите: waypoint proxy on)")")
        exit(0)
    }
    dispatchMain()

case "check":
    let hosts = Array(args.dropFirst())
    guard !hosts.isEmpty else { usage() }
    Task {
        let s = engine.settings
        engine.network.start()
        try? await Task.sleep(nanoseconds: 500_000_000)
        let up: (String, UInt16)? = await UpstreamProbe.isOpenSocks5(host: s.upstreamHost, port: s.upstreamPort) ? (s.upstreamHost, s.upstreamPort) : nil
        for h in hosts {
            let c = await Probe.compare(host: h, interface: engine.network.physical, upstream: up)
            let d = engine.rules.decide(host: h, port: 443)
            print("\(h)\n  напрямую: \(ms(c.direct))   через VPN: \(c.vpn.map(ms) ?? "—")\n  вывод:   \(c.verdict)\n  сейчас в правилах: \(d.action.rawValue) (\(d.source.rawValue))")
        }
        exit(0)
    }
    dispatchMain()

case "why":
    guard args.count > 1 else { usage() }
    let d = engine.rules.decide(host: args[1], port: 443)
    print("\(args[1]) → \(d.action.rawValue)  [источник: \(d.source.rawValue)]  ключ обучения: \(registrableDomain(args[1]))")

case "learned":
    switch args.dropFirst().first ?? "list" {
    case "list":
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        for e in engine.rules.learnedEntries { print("\(e.domain)\tвыучено \(f.string(from: e.learnedAt))\tподтверждений: \(e.hits)") }
        if engine.rules.learnedEntries.isEmpty { print("пусто") }
    case "clear": engine.rules.clearLearned(); print("очищено")
    case "forget": if args.count > 2 { engine.rules.forget(domain: args[2]); print("забыто") } else { usage() }
    default: usage()
    }

case "rules":
    switch args.dropFirst().first ?? "list" {
    case "list": engine.rules.manual.forEach { print($0.text) }
    case "add":
        guard args.count > 2, let r = ManualRule.parse(args[2]) else { print("не разобрал правило"); exit(1) }
        engine.rules.setManualRules(engine.rules.manual.filter { $0 != r } + [r]); print("добавлено: \(r.text)")
    case "remove":
        guard args.count > 2 else { usage() }
        let before = engine.rules.manual.count
        engine.rules.setManualRules(engine.rules.manual.filter { $0.text != args[2] })
        print(engine.rules.manual.count < before ? "удалено" : "такого правила нет")
    default: usage()
    }

case "conn":
    let home = engine.supportDirectory
    var list = ConnectionRuleStore.load(from: home)
    let servers = ServerStore.load(from: home)
    func describe(_ t: ConnectionTarget) -> String {
        if case .server(let id) = t { return "server:" + (servers.first { $0.id == id }?.name ?? "\(id) (нет такого)") }
        return t.raw
    }
    switch args.dropFirst().first ?? "list" {
    case "list":
        if list.isEmpty { print("правил нет") }
        for r in list { print("\(r.app.map(AppPath.displayName) ?? "*")  →  \(r.site ?? "*")  :  \(describe(r.target))") }
    case "add":
        var app: String?, site: String?, rest: [String] = []
        var i = 2
        while i < args.count {
            if args[i] == "--app", i + 1 < args.count { app = args[i + 1]; i += 2 }
            else if args[i] == "--site", i + 1 < args.count { site = args[i + 1]; i += 2 }
            else { rest.append(args[i]); i += 1 }
        }
        guard let raw = rest.first else { usage() }
        var target = ConnectionTarget(raw: raw)
        if raw.hasPrefix("server:") {       // by name as well as by id
            let q = String(raw.dropFirst(7)).lowercased()
            if let s = servers.first(where: { $0.id == q || $0.name.lowercased().contains(q) }) { target = .server(s.id) } else { print("сервер не найден: \(q)"); exit(1) }
        }
        guard let t = target, let r = ConnectionRule(app: app, site: site, target: t) else { print("не разобрал правило (нужен --app и/или --site и цель)"); exit(1) }
        list.removeAll { $0.id == r.id }; list.append(r)
        ConnectionRuleStore.save(list, to: home); print("добавлено: \(r.id) : \(describe(r.target))")
    case "remove":
        guard args.count > 3 else { usage() }
        let app = args[2] == "*" ? nil : AppPath.canonical(args[2]), site = args[3] == "*" ? nil : ConnectionRule.normalizeSite(args[3])
        let before = list.count
        list.removeAll { $0.app == app && $0.site == site }
        ConnectionRuleStore.save(list, to: home); print(list.count < before ? "удалено" : "такого правила нет")
    default: usage()
    }

case "proxy":
    let s = engine.settings
    switch args.dropFirst().first ?? "status" {
    case "on":
        do { try SystemProxy.apply(pacURL: s.pacURL); print("PAC применён: \(s.pacURL)\n(запущенный `waypoint run` или приложение должны работать; если их нет — сеть просто идёт напрямую)") }
        catch { fputs("\(error)\n", stderr); exit(1) }
    case "off":
        do { try SystemProxy.restore(); print("настройки прокси возвращены как были") } catch { fputs("\(error)\n", stderr); exit(1) }
    default:
        print("эффективный PAC: \(SystemProxy.effectivePACURL() ?? "нет")  ·  статус: \(SystemProxy.status(s.pacURL))")
    }

case "happ-sync":
    let l = HappRouting.lists(rules: engine.rules, region: engine.settings.region)
    let json = HappRouting.profileJSON(l)
    guard let url = HappRouting.deeplink(json, activate: args.contains("--activate")) else { exit(1) }
    print("Профиль «Waypoint»: через VPN — \(l.proxySites.count) доменов + \(l.proxyIP.count) сетей; напрямую — \(l.directSites.count) доменов; блок — \(l.blockSites.count).")
    if args.contains("--open") {
        NSWorkspace.shared.open(url)
        print("Отправлено в Happ. Подтвердите импорт в самом приложении.")
    } else {
        print("Без --open ничего не отправлено. Ссылка (\(url.absoluteString.count) символов):\n\(url.absoluteString)")
    }

case "tunnel":
    // waypoint tunnel gen --out DIR [--no-tun]   writes config.json + rule-sets into DIR (for `sing-box check` / no-root tests)
    let sub = args.dropFirst().first ?? ""
    switch sub {
    case "gen":
        guard let out = value(after: "--out") else { usage() }
        let noTun = args.contains("--no-tun")
        engine.network.start(); Thread.sleep(forTimeInterval: 0.6)
        let phys = engine.network.physical?.name ?? "en0"
        let happID = engine.settings.vpnServiceName.flatMap { VPNController.service(named: $0)?.id }
        let happIf = happID.flatMap { NetworkFacts.vpnInterface(serviceID: $0) } ?? "utun7"
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("rulesets"), withIntermediateDirectories: true)
        for (name, data) in TunnelConfig.ruleSets(rules: engine.rules, region: engine.settings.region) {
            try? data.write(to: dir.appendingPathComponent("rulesets/\(name).json"))
        }
        let p = TunnelParams(physicalInterface: phys, happInterface: happIf, racePort: engine.settings.listenPort,
                             directDNS: NetworkFacts.directDNS(interface: phys), ruleSetDir: dir.appendingPathComponent("rulesets").path,
                             cachePath: dir.appendingPathComponent("cache.db").path, tun: !noTun)
        do { try TunnelConfig.generate(p).write(to: dir.appendingPathComponent("config.json")); print("written \(dir.path)/config.json  (phys=\(phys) vpn=\(happIf) dns=\(p.directDNS) tun=\(!noTun))") }
        catch { fputs("\(error)\n", stderr); exit(1) }
    case "daemon":
        // Root-run supervisor (installed as a LaunchDaemon). --no-tun runs the same logic without a TUN, for tests as a normal user.
        guard let home = value(after: "--home"), let sb = value(after: "--sing-box"), let state = value(after: "--state") else { usage() }
        try? FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let d = TunnelDaemon(.init(home: URL(fileURLWithPath: home), singBox: URL(fileURLWithPath: sb), state: URL(fileURLWithPath: state),
                                   tun: !args.contains("--no-tun"), mixedPort: value(after: "--mixed-port").flatMap(UInt16.init) ?? 7811,
                                   apiPort: value(after: "--api-port").flatMap(UInt16.init) ?? 9097))
        d.run()
    case "conns":
        // Live connections of the whole system (needs the daemon): application, address, path, carrier.
        guard let api = ClashClient() else { print("демон не запущен или туннель выключен (нет API)"); exit(1) }
        Task {
            do {
                let snap = try await api.connections()
                let filter = args.dropFirst(2).first
                for c in snap.connections.sorted(by: { $0.download > $1.download }) where filter == nil || c.appName.localizedCaseInsensitiveContains(filter!) || c.host.contains(filter!) {
                    print("\(c.appName.padding(toLength: 16, withPad: " ", startingAt: 0)) \(c.path.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \("\(c.host):\(c.port)".padding(toLength: 42, withPad: " ", startingAt: 0)) ↑\(c.upload) ↓\(c.download)  [\(c.chain.joined(separator: " > "))]")
                }
                print("всего: \(snap.connections.count)")
            } catch { print("ошибка API: \(error)") }
            exit(0)
        }
        dispatchMain()
    case "on", "off":
        let flag = AppSettings.supportDirectory.appendingPathComponent("tunnel.enabled")
        try? FileManager.default.createDirectory(at: AppSettings.supportDirectory, withIntermediateDirectories: true)
        if sub == "on" { FileManager.default.createFile(atPath: flag.path, contents: Data()); print("флаг включения создан — демон запустит туннель, если VPN подключён и Waypoint работает") }
        else { try? FileManager.default.removeItem(at: flag); print("туннель выключается") }
    case "status":
        let path = value(after: "--file") ?? TunnelStatus.defaultPath
        if let st = TunnelStatus.read(path: path) { print("\(st.state.rawValue): \(st.message)  [физ: \(st.physical ?? "—"), VPN: \(st.vpn ?? "—")]") }
        else { print("демон не установлен или не запущен (нет \(path))") }
    default: usage()
    }

case "sub":
    // waypoint sub test <link>: download a subscription and show what it contains — nothing is saved, the link is not printed.
    guard args.count >= 3, args[1] == "test" else { usage() }
    Task {
        let target: String
        switch SubscriptionLink.classify(args[2]) {
        case .subscription(let u): target = u
        case .encrypted: print("Зашифрованная ссылка Happ — открыть её может только Happ. Нужна обычная ссылка подписки https://…"); exit(1)
        case .insecure: print("Нужна защищённая ссылка https://"); exit(1)
        case .notASubscription: print("Это не ссылка подписки (для одного сервера используйте экран «Серверы»)."); exit(1)
        }
        let st = engine.settings
        let socks: (String, UInt16)? = await UpstreamProbe.isOpenSocks5(host: st.upstreamHost, port: st.upstreamPort) ? (st.upstreamHost, st.upstreamPort) : nil
        do {
            var r: Subscription.FetchResult
            do { r = try await Subscription.fetch(target, socks: socks) }
            catch { guard socks != nil else { throw error }; print("через VPN не вышло (\(error)), пробую напрямую…"); r = try await Subscription.fetch(target, socks: nil) }
            print("Подписка: \(r.title ?? (URL(string: target)?.host ?? "—"))")
            if let i = r.info {
                let f = ByteCountFormatter()
                print("Трафик: \(f.string(fromByteCount: Int64(i.used)))" + ((i.total ?? 0) > 0 ? " из \(f.string(fromByteCount: Int64(i.total!)))" : "") + (i.expire.map { " · до \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
            }
            if let h = r.updateHours { print("Провайдер просит обновлять раз в \(h) ч") }
            print("Серверов: \(r.parsed.servers.count)")
            for srv in r.parsed.servers {
                let ru = st.region == .russia && Subscription.looksRussian(srv.server.name)
                print("  \(ru ? "○" : "●") \(srv.server.name) — \(srv.server.proto.uppercased()) \(srv.server.host)\(ru ? "  (в России — будет выключен)" : "")")
            }
            if r.parsed.skippedCount > 0 {
                print("Пропущено: \(r.parsed.skippedCount)")
                for (why, n) in r.parsed.skipped.sorted(by: { $0.value > $1.value }) { print("  · \(why) — \(n)") }
            }
        } catch { print("Не получилось: \(error)"); exit(1) }
        exit(0)
    }
    dispatchMain()

case "servers":
    // waypoint servers audit [--log FILE]: which of your servers work, how fast, and which country they exit in
    guard args.dropFirst().first == "audit" else { usage() }
    Task {
        engine.network.start()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let phys = engine.network.physical?.name ?? "en0"
        let dirs = [FileManager.default.currentDirectoryPath + "/vendor", NSHomeDirectory() + "/Applications/Waypoint.app/Contents/Resources", NSHomeDirectory() + "/Documents/Waypoint/vendor"]
        let sb = (["/usr/local/libexec/waypoint/sing-box"] + dirs.map { $0 + "/sing-box" }).first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/libexec/waypoint/sing-box"
        let xr = dirs.map { $0 + "/xray" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        let list = ServerStore.load(from: engine.supportDirectory)
        print("Проверяю \(list.count) серверов через \(phys) (не через VPN)…")
        let res = await ServerAudit.run(servers: list, singBox: URL(fileURLWithPath: sb), xray: xr.map { URL(fileURLWithPath: $0) }, interface: phys, directDNS: NetworkFacts.directDNS(interface: phys),
                                        logTo: value(after: "--log").map { URL(fileURLWithPath: $0) },
                                        tlsExtra: args.contains("--fragment") ? ["fragment": true] : (args.contains("--record-fragment") ? ["record_fragment": true] : [:]))
        for r in res {
            let exit = r.country.map { "выход \(Diagnostics.country($0))" } ?? ""
            let msText = (r.ms.map { "\($0) мс" } ?? "").padding(toLength: 8, withPad: " ", startingAt: 0)
            let mark = r.ok ? "✓" : "✗"
            print("\(mark) \(r.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(msText) \((r.engine ?? "").padding(toLength: 9, withPad: " ", startingAt: 0)) \(exit)\(r.error ?? "")")
        }
        print("работают: \(res.filter(\.ok).count) из \(res.count)")
        exit(0)
    }
    dispatchMain()

case "vpn":
    // waypoint vpn status|start|stop — the same launcher the app uses at login
    let sub = args.dropFirst().first ?? "status"
    let name = engine.settings.vpnServiceName ?? "Happ"
    switch sub {
    case "status":
        let s = VPNController.service(named: name)
        print("\(name): \(s?.state ?? "не найден")")
    case "stop":
        print(VPNController.stop(name) ? "остановлен: \(name)" : "не удалось остановить")
    case "start":
        Task {
            let t0 = Date()
            let r = await VPNLauncher.ensureRunning(settings: engine.settings, log: { print("  \($0)") })
            print("результат: \(r)  (за \(Int(Date().timeIntervalSince(t0))) с)")
            exit(0)
        }
        dispatchMain()
    default: usage()
    }

case "pac":
    print(PAC.script(port: engine.settings.listenPort))

default:
    usage()
}
