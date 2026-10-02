import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import CoreServices
import WaypointCore

enum Screen: String, CaseIterable, Identifiable {
    case overview, scenarios, services, apps, sites, activity, servers, diagnostics, settings
    var id: String { rawValue }

    /// Sidebar groups (System Settings style: separated by space, no titles).
    static let groups: [[Screen]] = [[.scenarios, .services, .apps, .sites], [.activity, .servers, .diagnostics], [.settings]]

    var title: String {
        switch self {
        case .overview: "Обзор"; case .scenarios: "Сценарии"; case .services: "Сервисы"; case .apps: "Приложения"; case .sites: "Сайты"
        case .activity: "Активность"; case .servers: "Серверы"; case .diagnostics: "Диагностика"; case .settings: "Настройки"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "signpost.right.and.left.fill"; case .scenarios: "wand.and.stars"; case .services: "square.grid.3x3.fill"
        case .apps: "app.badge.checkmark"; case .sites: "globe"; case .activity: "waveform.path.ecg"; case .servers: "server.rack"
        case .diagnostics: "stethoscope"; case .settings: "gearshape.fill"
        }
    }
    var color: Color {
        switch self {
        case .overview: .blue; case .scenarios: .purple; case .services: .pink; case .apps: .orange; case .sites: .blue
        case .activity: .teal; case .servers: .indigo; case .diagnostics: .green; case .settings: .gray
        }
    }
    /// Short description under the page title.
    var subtitle: String {
        switch self {
        case .overview: "Состояние Waypoint"
        case .scenarios: "Готовые наборы правил: один переключатель — и группа сервисов идёт нужным путём."
        case .services: "Выберите путь для отдельного сервиса. «Авто» — Waypoint решит сам."
        case .apps: "Правило для приложения целиком — для всех его соединений."
        case .sites: "Ваши правила для сайтов и то, что Waypoint выучил сам."
        case .activity: "Что прямо сейчас выходит в сеть и каким путём."
        case .servers: "Через что идёт трафик, которому нужен VPN."
        case .diagnostics: "Проверка всей цепочки: сеть, VPN, режим «Все приложения» и популярные сервисы."
        case .settings: "Запуск, VPN-клиент, обучение и данные."
        }
    }
    /// Plain-language explanation behind «Подробнее…».
    var help: String {
        switch self {
        case .overview: "Waypoint сам решает, как идёт каждое соединение: заблокированное — через ваш VPN, всё остальное — напрямую, быстро и без траты трафика VPN."
        case .scenarios: "Например, «TikTok — свежая лента» отправляет весь TikTok через VPN, чтобы лента была не российской, а «Банки — только напрямую» не пускает банки через чужой адрес, даже если Waypoint где-то ошибся.\n\nВаш выбор на странице «Сервисы» важнее сценария."
        case .services: "«Через VPN» — всегда через VPN, «Напрямую» — всегда мимо VPN, «Блокировать» — не пускать вовсе. «Авто» — как решат встроенные подсказки, списки и автообучение. Ваш выбор важнее любого сценария."
        case .apps: "Например, «Discord — через VPN»: правило действует на все процессы приложения, к каким бы адресам оно ни обращалось. Работает, когда включён режим «Все приложения»."
        case .sites: "Ваши правила важнее всего остального. «Выучено» — сайты, которые напрямую не открылись, а через VPN открылись; Waypoint перепроверяет их и забывает, когда блокировку снимают."
        case .activity: "«Соединения» — каждое активное соединение: приложение, адрес, путь и объём. Правый клик — правило для приложения или сайта.\n\n«Проверки» — как Waypoint определял незнакомые сайты: какой путь сработал и что выучено (★)."
        case .servers: "По умолчанию трафик через VPN идёт через ваш VPN-клиент. Можно добавить свои серверы по ссылке (vless://, trojan://, ss://, hysteria2://, vmess://) — тогда Waypoint сам выберет самый быстрый отдельно для видео, AI, звонков и остального."
        case .diagnostics: "Проверка ничего не меняет, только измеряет. Отчёт можно скопировать и приложить к issue на GitHub."
        case .settings: "Большинству ничего менять не нужно."
        }
    }
}

struct AppInfo: Identifiable, Hashable {
    let path: String
    let name: String
    let uses: Int
    var id: String { path }
}

@Observable @MainActor
final class AppModel {
    let engine = Engine()

    // engine / data
    var settings: AppSettings
    var running = false
    var startError: String?
    var events: [RouteEvent] = []
    var learned: [LearnedEntry] = []
    var manualText = ""
    var servers: [ServerEntry] = []
    var subscriptions: [SubscriptionEntry] = []
    var subscriptionBusy: Set<String> = []
    var serverDelays: [String: Int] = [:]          // server id → ms of the last speed test
    var serverDelayFailed: Set<String> = []
    var serverTesting = false

    // tunnel + live view
    var tunnel: TunnelStatus?
    var tunnelWanted = false
    var connections: [LiveConnection] = []
    var traffic = TrafficStats()
    var history: [TrafficPoint] = []
    var pools: [PoolClass: PoolInfo] = [:]
    var apiOK = false
    @ObservationIgnored private let tracker = TrafficTracker()
    @ObservationIgnored private var api: ClashClient?
    @ObservationIgnored private var apiStamp = ""
    @ObservationIgnored private var lastPoolFetch = Date.distantPast
    @ObservationIgnored private var raceOutcome: [String: String] = [:]      // host → "direct" | "vpn", from the racer's own decisions

    // system state
    var upstreamOK = false
    var vpnState = "—"
    var interfaceName = "—"
    var proxyApplied = false
    var proxyIgnored = false
    var vpnServices: [String] = []
    var vpnBusy = false
    var launchAtLogin = false

    // apps
    var installedApps: [AppInfo] = []
    var appRoutes: [String: Route] = [:]
    /// Per-connection rules (app / site / app+site → any target, including one exact server).
    var connectionRules: [ConnectionRule] = []
    @ObservationIgnored var lastSubscriptionAttempt: [String: Date] = [:]

    // lists / diagnostics / misc
    var communityInstalled: Set<String> = []
    var communityBusy = false
    var communityMessage: String?
    var diag: [DiagCheck] = []
    var diagRunning = false
    var diagAt: Date?
    var toast: String?
    private(set) var screen: Screen = .overview
    private(set) var backStack: [Screen] = []
    private(set) var forwardStack: [Screen] = []
    var exitDirect: String?          // ISO country codes the internet sees, per path
    var exitVPN: String?
    @ObservationIgnored private var exitCheckedAt = Date.distantPast
    var showOnboarding = false
    var daemonBusy = false
    var auditRunning = false
    var auditAt: Date?
    @ObservationIgnored private(set) lazy var xray = XrayRunner(binary: Self.helperBinary("xray"), dir: engine.supportDirectory.appendingPathComponent("xray", isDirectory: true))

    // "current site" for the menu popover
    var currentHost: String?
    var currentDecision: Decision?
    var currentIsPinned: Route?
    var lastBrowser: String?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var wantsSystemProxy: Bool {
        get { UserDefaults.standard.bool(forKey: "wantsSystemProxy") }
        set { UserDefaults.standard.set(newValue, forKey: "wantsSystemProxy") }
    }
    @ObservationIgnored private var lastTunnelState: TunnelStatus.State?
    @ObservationIgnored private var lastVPNConnected: Bool?
    @ObservationIgnored private var lastReconnect = Date.distantPast
    @ObservationIgnored var visible = false          // a window / popover is on screen: poll faster

    /// Menu bar icon reflects what matters: is anything actually being routed for the whole system?
    var iconName: String {
        if tunnel?.state == .running { return "signpost.right.and.left.fill" }
        if running && proxyApplied { return "signpost.right.and.left.fill" }
        return "signpost.right.and.left"
    }
    var tunnelRunning: Bool { tunnel?.state == .running || tunnel?.state == .starting }
    var tunnelInstalled: Bool { tunnel != nil }
    /// The installed system component is an older build than the one inside this app (new features need an update).
    var daemonOutdated: Bool {
        guard tunnelInstalled, let res = Bundle.main.resourceURL else { return false }
        let fm = FileManager.default
        func same(_ name: String) -> Bool {
            let a = res.appendingPathComponent(name).path, b = "/usr/local/libexec/waypoint/\(name)"
            guard fm.fileExists(atPath: a), fm.fileExists(atPath: b) else { return true }
            return fm.contentsEqual(atPath: a, andPath: b)
        }
        let xrayMissing = fm.fileExists(atPath: res.appendingPathComponent("xray").path) && !fm.fileExists(atPath: "/usr/local/libexec/waypoint/xray")
        return !same("waypoint") || !same("sing-box") || xrayMissing || tunnel?.xrayManaged != true
    }
    var vpnConnected: Bool { vpnState == "Connected" }

    /// Overall health in one line for the hero card.
    var headline: (text: String, color: Color, symbol: String) {
        if let e = startError { return (e, .wpBad, "exclamationmark.octagon.fill") }
        if !upstreamOK && settings.vpnServiceName != nil { return ("VPN недоступен — заблокированное не откроется", .wpBad, "bolt.horizontal.circle.fill") }
        if tunnel?.state == .error { return ("Туннель остановил себя — сеть работает как обычно", .wpWarn, "exclamationmark.triangle.fill") }
        if tunnel?.state == .running { return ("Всё работает: каждое приложение идёт нужным путём", .wpDirect, "checkmark.seal.fill") }
        if tunnelWanted { return ("Туннель ждёт условий: \(tunnel?.message ?? "запуск…")", .wpWarn, "hourglass") }
        if proxyApplied { return ("Работает для браузеров и приложений с прокси", .wpVPN, "checkmark.circle.fill") }
        return ("Включите туннель, чтобы охватить все приложения", .wpWarn, "power.circle.fill")
    }

    /// One or two words for the window toolbar (the long sentence lives on the Overview hero).
    var shortStatus: String {
        if startError != nil { return "Ошибка запуска" }
        if !upstreamOK && settings.vpnServiceName != nil { return "VPN недоступен" }
        if tunnel?.state == .error { return "Туннель на паузе" }
        if tunnel?.state == .running { return "Всё работает" }
        if tunnelWanted { return "Туннель запускается" }
        return proxyApplied ? "Работает для браузеров" : "Туннель выключен"
    }

    // MARK: init

    init(preview: Bool = false) {
        settings = engine.settings
        manualText = ManualRule.serialize(engine.rules.manual)
        learned = engine.rules.learnedEntries
        servers = ServerStore.load(from: engine.supportDirectory)
        subscriptions = SubscriptionStore.load(from: engine.supportDirectory)
        connectionRules = ConnectionRuleStore.load(from: engine.supportDirectory)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        syncAppRoutes()
        if preview { loadPreviewData(); return }

        engine.onEvent = { [weak self] e in Task { @MainActor in self?.push(e) } }
        engine.onLearned = { [weak self] l in
            Task { @MainActor in
                self?.learned = self?.engine.rules.learnedEntries ?? []
                self?.notify("Выучено: \(l.domain)", "Теперь этот сайт открывается через VPN")
            }
        }
        engine.rules.onForgotten = { [weak self] _ in Task { @MainActor in self?.learned = self?.engine.rules.learnedEntries ?? [] } }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier, Browsers.scripts[id] != nil else { return }
            Task { @MainActor in self?.lastBrowser = id }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.xray.stop() }
            if UserDefaults.standard.bool(forKey: "wantsSystemProxy") { try? SystemProxy.restore(allowPrompt: false) }
        }
        if let front = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier.map { Browsers.scripts[$0] != nil } ?? false }) { lastBrowser = front.bundleIdentifier }

        Task { await start() }
        Task { while true { try? await Task.sleep(nanoseconds: 300_000_000_000); await refreshStaleSubscriptions() } }   // every 5 min: is any subscription due?
        // Slow loop: system state (scutil, networksetup). Fast loop: live connections — short flows must not slip between polls.
        Task { while true { await refresh(); try? await Task.sleep(nanoseconds: visible ? 1_500_000_000 : 4_000_000_000) } }
        Task { while true { await pollAPI(); try? await Task.sleep(nanoseconds: 1_000_000_000) } }
        // Watchdog for the Xray helper: restarts it if it died and re-binds it when the network interface changed
        // (Wi-Fi ↔ cable, sleep/wake). Without it every Xray-carried server stayed dead until the next manual action.
        Task { while true { try? await Task.sleep(nanoseconds: 5_000_000_000); if running { syncXray() } } }   // no-op once the daemon manages Xray
        // Servers the checker switched off (or that failed lately) get another look every 20 minutes and return by themselves.
        Task { try? await Task.sleep(nanoseconds: 90_000_000_000); while true { await recheckServers(); try? await Task.sleep(nanoseconds: 1_200_000_000_000) } }
        Task { [weak self] in
            let apps = await Task.detached { Self.scanApps() }.value
            self?.installedApps = apps
        }
        if settings.onboardingDone != true { showOnboarding = true }
    }

    // MARK: engine

    func start() async {
        do {
            try await engine.start()
            running = true; startError = nil
            if wantsSystemProxy, !SystemProxy.isApplied(engine.settings.pacURL) { try? SystemProxy.apply(pacURL: engine.settings.pacURL, allowPrompt: false) }
            if settings.autoStartVPN ?? true { await ensureVPN(quiet: true) }
            if settings.communityLists == true { Task { await updateCommunityLists(silent: true) } }
            Task { await refreshStaleSubscriptions() }
            xray.killStale()
            syncXray()
            let unchecked = Set(servers.filter { $0.checked == nil }.map(\.id))
            if !unchecked.isEmpty { Task { await auditServers(ids: unchecked) } }
        } catch {
            running = false
            startError = "Порт \(engine.settings.listenPort) занят или недоступен: \(error.localizedDescription)"
        }
    }

    func push(_ e: RouteEvent) {
        if e.source == "race" || e.source == "manual" || e.source == "learned" { raceOutcome[e.host] = e.route }
        if raceOutcome.count > 2000 { raceOutcome.removeAll(keepingCapacity: true) }
        events.insert(e, at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }
    }

    // MARK: polling

    func refresh() async {
        let s = engine.settings
        interfaceName = engine.network.physical?.name ?? "—"
        let state = await Task.detached { () -> (Bool, String, SystemProxy.Status, [String], TunnelStatus?) in
            let up = await UpstreamProbe.isOpenSocks5(host: s.upstreamHost, port: s.upstreamPort, timeoutMs: 500)
            let list = VPNController.list()
            let st = s.vpnServiceName.flatMap { n in list.first { $0.name == n }?.state } ?? "—"
            return (up, st, SystemProxy.status(s.pacURL), list.map(\.name), TunnelStatus.read())
        }.value
        upstreamOK = state.0; vpnState = state.1; proxyApplied = state.2 == .active; proxyIgnored = state.2 == .ignoredByVPN; vpnServices = state.3
        let newTunnel = state.4
        tunnelWanted = FileManager.default.fileExists(atPath: engine.supportDirectory.appendingPathComponent("tunnel.enabled").path)
        reportTransitions(old: lastTunnelState, new: newTunnel?.state, message: newTunnel?.message)
        lastTunnelState = newTunnel?.state; tunnel = newTunnel
        reportVPN(connected: state.1 == "Connected")
        communityInstalled = Set(CommunityListUpdater.installed(home: engine.supportDirectory).map(\.id))
    }

    func pollAPI() async {
        guard tunnel?.state == .running || tunnel?.state == .starting else { connections = []; apiOK = false; api = nil; return }
        if let info = TunnelAPIInfo.read() {
            let stamp = "\(info.port)|\(info.secret)"
            if stamp != apiStamp { api = ClashClient(info: info); apiStamp = stamp }
        }
        guard let api else { apiOK = false; return }
        do {
            var snap = try await api.connections()
            snap.connections = snap.connections.map { $0.resolving(raceOutcome: raceOutcome[$0.host]) }
            apiOK = true
            connections = snap.connections
            traffic = tracker.ingest(snap)
            history.append(TrafficPoint(t: Date(), up: traffic.upRate, down: traffic.downRate))
            if history.count > 90 { history.removeFirst(history.count - 90) }
            if Date().timeIntervalSince(lastPoolFetch) > 10, servers.contains(where: \.enabled) {
                lastPoolFetch = Date()
                for c in PoolClass.allCases { if let p = try? await api.pool("pool-\(c.rawValue)") { pools[c] = p } }
            }
        } catch { apiOK = false }
    }

    // MARK: notifications

    func notify(_ title: String, _ body: String) {
        flash("\(title) — \(body)")
        guard settings.notifications ?? true, Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func reportTransitions(old: TunnelStatus.State?, new: TunnelStatus.State?, message: String?) {
        guard let old, let new, old != new else { return }
        if new == .error { notify("Туннель остановлен", message ?? "самотест не прошёл — сеть работает как обычно") }
        if old == .error && new == .running { notify("Туннель восстановлен", "снова работает для всех приложений") }
    }

    private func reportVPN(connected: Bool) {
        defer { lastVPNConnected = connected }
        guard let last = lastVPNConnected, last != connected else { return }
        if !connected {
            notify("VPN отключился", "заблокированное не откроется, пока он выключен")
            // Opt-in only: a user who switches the VPN off on purpose must not be fought. At most one attempt per 2 minutes.
            if settings.reconnectVPN == true, Date().timeIntervalSince(lastReconnect) > 120 {
                lastReconnect = Date()
                Task { await ensureVPN(quiet: true) }
            }
        }
    }

    func flash(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(nanoseconds: 4_500_000_000); if !Task.isCancelled { toast = nil } }
    }

    // MARK: VPN client

    func ensureVPN(quiet: Bool = false) async {
        vpnBusy = true; defer { vpnBusy = false }
        let s = engine.settings
        let outcome = await VPNLauncher.ensureRunning(settings: s)
        switch outcome {
        case .alreadyUp: if !quiet { flash("VPN уже подключён") }
        case .started, .startedViaApp: flash("VPN запущен")
        case .failed(let why): flash("VPN не запустился: \(why)")
        }
        await refresh()
    }

    // MARK: system proxy (PAC)

    func setSystemProxy(_ on: Bool) {
        let url = engine.settings.pacURL
        Task {
            let err: String? = await Task.detached {
                do { if on { try SystemProxy.apply(pacURL: url) } else { try SystemProxy.restore() }; return nil } catch { return "\(error)" }
            }.value
            if let err { flash(err) } else { wantsSystemProxy = on }
            await refresh()
        }
    }

    // MARK: tunnel

    func setTunnel(_ on: Bool) {
        let flag = engine.supportDirectory.appendingPathComponent("tunnel.enabled")
        try? FileManager.default.createDirectory(at: engine.supportDirectory, withIntermediateDirectories: true)
        if on { FileManager.default.createFile(atPath: flag.path, contents: Data()) } else { try? FileManager.default.removeItem(at: flag) }
        tunnelWanted = on
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await refresh() }
    }

    /// Runs the bundled installer with the standard macOS administrator prompt (password / Touch ID). Nothing is installed without it.
    func installDaemon() {
        guard let res = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: res.appendingPathComponent("install-daemon.sh").path) else {
            flash("В этой сборке нет установщика: выполните scripts/install-daemon.sh из папки проекта"); return
        }
        runPrivileged(script: "install-daemon.sh", resources: res, done: tunnelInstalled ? "Компонент обновлён" : "Компонент установлен — теперь включите «Все приложения»")
    }

    func uninstallDaemon() {
        guard let res = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: res.appendingPathComponent("uninstall-daemon.sh").path) else { flash("Нет uninstall-daemon.sh"); return }
        runPrivileged(script: "uninstall-daemon.sh", resources: res, done: "Компонент удалён")
    }

    private func runPrivileged(script: String, resources: URL, done: String) {
        daemonBusy = true
        let user = NSUserName(), dir = resources.path
        Task {
            let r: (Int32, String) = await Task.detached {
                let cmd = "'\(dir)/\(script)' --payload '\(dir)' --user '\(user)'"
                let apple = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
                let p = runProcessPublic("/usr/bin/osascript", ["-e", apple])
                return (p.code, (p.err.isEmpty ? p.out : p.err).trimmingCharacters(in: .whitespacesAndNewlines))
            }.value
            daemonBusy = false
            flash(r.0 == 0 ? done : "Не получилось: \(r.1.prefix(200))")
            await refresh()
        }
    }

    // MARK: rules, services, scenarios

    func syncAppRoutes() {
        var m: [String: Route] = [:]
        for r in engine.rules.manual where r.kind == .app { m[r.value] = r.route }
        appRoutes = m
    }

    // MARK: appearance

    /// Light, dark, or (nil) whatever the system uses. Applies to every window, the tray panel and sheets.
    func applyAppearance() {
        switch settings.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    func setAppearance(_ value: String?) { applySettings { $0.appearance = value }; applyAppearance() }
    /// The toolbar button: flips between light and dark, starting from what is on screen now.
    func toggleAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        setAppearance(dark ? "light" : "dark")
    }

    func applySettings(_ change: (inout AppSettings) -> Void) {
        engine.update(change)
        settings = engine.settings
    }

    func setAppRoute(_ path: String, _ route: Route?) {
        let key = AppPath.canonical(path)
        var rules = engine.rules.manual.filter { !($0.kind == .app && $0.value == key) }
        if let route, AppPath.isValid(key) { rules.append(ManualRule(route: route, kind: .app, value: key)) }
        engine.rules.setManualRules(rules)
        manualText = ManualRule.serialize(engine.rules.manual)
        syncAppRoutes()
        if !tunnelRunning && route != nil { flash("Правило для приложения работает, когда включён режим «Все приложения»") }
    }

    // MARK: per-connection targets
    //
    // One entry point for «where does this go»: an app, a site, or an app talking to a site. The three plain routes of an
    // app or a site stay in rules.txt (the in-app router and `waypoint rules` understand them); everything else —
    // the VPN client alone, one exact server, any app+site pair — lives in connection-rules.json, which the daemon
    // turns into hot-reloaded rule-sets.

    func target(app: String?, site: String?) -> ConnectionTarget? {
        let a = app.map(AppPath.canonical), s = site.flatMap(ConnectionRule.normalizeSite)
        if let r = connectionRules.first(where: { $0.app == a && $0.site == s }) { return r.target }
        if let a, s == nil { return appRoutes[a].map(ConnectionTarget.init) }
        if a == nil, let s { return siteRule(s).map { ConnectionTarget($0.route) } }
        return nil
    }

    /// Manual rule for exactly this site (domain with subdomains, or the CIDR).
    private func siteRule(_ s: String) -> ManualRule? {
        engine.rules.manual.first { ($0.kind == .suffix || $0.kind == .cidr) && $0.value == s }
    }

    func setTarget(app: String?, site: String?, _ t: ConnectionTarget?) {
        guard let rule = ConnectionRule(app: app, site: site, target: t ?? .vpn) else { flash("Не похоже на адрес сайта"); return }
        connectionRules.removeAll { $0.id == rule.id }
        switch rule.tier {
        case .app:
            setAppRoute(rule.app!, t?.route)
            if let t, t.route == nil { connectionRules.append(rule) }
        case .site:
            if let old = siteRule(rule.site!) { engine.rules.setManualRules(engine.rules.manual.filter { $0 != old }) }
            if let r = t?.route { _ = addSite(rule.site!, route: r) }
            else if t != nil { connectionRules.append(rule); engine.rules.forget(domain: rule.site!) }
            manualText = ManualRule.serialize(engine.rules.manual); learned = engine.rules.learnedEntries
        case .pair:
            if t != nil { connectionRules.append(rule) }
        }
        ConnectionRuleStore.save(connectionRules, to: engine.supportDirectory)
        if t != nil && !tunnelRunning { flash("Правило сработает, когда включён режим «Все приложения»") }
        else if case .server(let id)? = t, servers.first(where: { $0.id == id })?.enabled != true {
            flash("Этот сервер выключен — пока он не включён, соединения пойдут через лучший VPN")
        }
    }

    /// Rules that name this app together with a site.
    func siteExceptions(for app: String) -> [ConnectionRule] {
        let a = AppPath.canonical(app)
        return connectionRules.filter { $0.app == a && $0.site != nil }.sorted { $0.site! < $1.site! }
    }

    func targetTitle(_ t: ConnectionTarget?) -> String {
        switch t {
        case nil: return "Авто"
        case .vpn?: return "Через VPN"
        case .direct?: return "Напрямую"
        case .block?: return "Блокировать"
        case .client?: return "Только \(settings.vpnServiceName ?? "VPN-клиент")"
        case .server(let id)?:
            guard let s = servers.first(where: { $0.id == id }) else { return "Сервер удалён" }
            let (flag, title) = ServerName.split(s.name)
            return [flag, title].compactMap { $0 }.joined(separator: " ") + (s.enabled ? "" : " (выкл.)")
        }
    }
    func targetColor(_ t: ConnectionTarget?) -> Color? {
        switch t { case nil: nil; case .direct?: .wpDirect; case .block?: .gray; default: .wpVPN }
    }

    func servicePolicy(_ id: String) -> Route? { settings.servicePolicies?[id].flatMap(Route.init(rawValue:)) }
    func setServicePolicy(_ id: String, _ route: Route?) {
        applySettings { var p = $0.servicePolicies ?? [:]; if let route { p[id] = route.rawValue } else { p.removeValue(forKey: id) }; $0.servicePolicies = p }
    }

    func isActive(_ playbook: String) -> Bool { settings.playbooks?.contains(playbook) ?? false }
    func setPlaybook(_ id: String, _ on: Bool) {
        applySettings { var l = $0.playbooks ?? []; l.removeAll { $0 == id }; if on { l.append(id) }; $0.playbooks = l }
        if let p = Playbook.playbook(id), on {
            flash("«\(p.title)» включён" + (p.udpViaVPN || p.finalMode != nil ? " — применится за пару секунд" : ""))
            if p.appHints.isEmpty == false && !tunnelInstalled { flash("Для приложений и звонков нужен режим «Все приложения»") }
        }
    }

    func pin(_ host: String, _ route: Route?) {
        engine.rules.pin(host: host, route: route)
        manualText = ManualRule.serialize(engine.rules.manual)
        learned = engine.rules.learnedEntries
        refreshCurrentDecision()
    }

    func saveManualRules() {
        engine.rules.setManualRules(ManualRule.parseAll(manualText))
        manualText = ManualRule.serialize(engine.rules.manual)
        syncAppRoutes()
        flash("Правила сохранены")
    }

    func forget(_ domain: String) { engine.rules.forget(domain: domain); learned = engine.rules.learnedEntries }
    func clearLearned() { engine.rules.clearLearned(); learned = [] }

    // MARK: servers

    func addServer(link: String) -> String? {
        do {
            let p = try ShareLink.parse(link)
            let entry = ServerEntry(name: p.name, link: link.trimmingCharacters(in: .whitespacesAndNewlines))
            servers.append(entry); ServerStore.save(servers, to: engine.supportDirectory)
            flash("Сервер «\(p.name)» добавлен (\(p.proto.uppercased()), \(p.host)) — применится при перезапуске туннеля")
            return nil
        } catch { return "\(error)" }
    }
    func removeServer(_ id: String) { servers.removeAll { $0.id == id }; ServerStore.save(servers, to: engine.supportDirectory); syncXray() }
    func toggleServer(_ id: String) {
        if let i = servers.firstIndex(where: { $0.id == id }) { servers[i].enabled.toggle(); ServerStore.save(servers, to: engine.supportDirectory); syncXray() }
    }
    func testServer(_ id: String) async -> Int? {
        guard let api, let i = ServerStore.outbounds(servers).first(where: { $0.entry.id == id }) else { return nil }
        return await api.delay(of: i.tag, url: PoolClass.general.testURL)
    }

    // MARK: helper engines

    /// sing-box / xray shipped inside the app bundle (or the project's vendor folder when run from a build dir).
    nonisolated static func helperBinary(_ name: String) -> URL {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(name).path,
                          NSHomeDirectory() + "/Documents/Waypoint/vendor/" + name].compactMap { $0 }
        return URL(fileURLWithPath: candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0])
    }

    /// Keep the Xray helper in sync with the enabled Xray-engine servers.
    /// With the daemon in charge of Xray (it survives the app closing and is supervised there) the app keeps none of its own:
    /// two helpers would fight over the same local ports.
    func syncXray() {
        if tunnel?.xrayManaged == true { if xray.isRunning { xray.stop() }; return }
        xray.apply(servers: servers, interface: engine.network.physical?.name ?? "en0")
    }

    /// Check servers with both engines; pick the engine that works, record the real exit country. On a server's first
    /// check, switch it off if it does not work or (in the Russian region) exits inside Russia; later it is the user's choice.
    /// Quiet re-check of servers that are off because of the checker, or failed recently.
    func recheckServers() async {
        guard running, !auditRunning, upstreamOK else { return }
        let ids = Set(ServerHealth.needsRecheck(servers).map(\.id))
        if !ids.isEmpty { await auditServers(ids: ids, quiet: true) }
    }

    func auditServers(ids: Set<String>? = nil, quiet: Bool = false) async {
        guard !auditRunning, !servers.isEmpty else { return }
        auditRunning = true
        defer { auditRunning = false }
        let phys = engine.network.physical?.name ?? "en0"
        let target = servers.filter { ids == nil || ids!.contains($0.id) }
        let dns = await Task.detached { NetworkFacts.directDNS(interface: phys) }.value
        let results = await ServerAudit.runWithRetry(servers: target, singBox: Self.helperBinary("sing-box"), xray: Self.helperBinary("xray"), interface: phys, directDNS: dns)
        let summary = ServerHealth.apply(results, to: &servers, russia: engine.settings.region == .russia)
        ServerStore.assignPorts(&servers)
        ServerStore.save(servers, to: engine.supportDirectory)
        auditAt = Date()
        syncXray()
        if summary.ignoredAsNetworkProblem {
            flash("Почти все серверы не ответили сразу — похоже на проблему с сетью. Ничего не выключено, проверю позже")
        } else if !quiet || !summary.recovered.isEmpty || !summary.switchedOff.isEmpty {
            var text = "Проверено: работают \(summary.ok) из \(summary.total)"
            if !summary.recovered.isEmpty { text += " · вернулись: \(summary.recovered.count)" }
            if !summary.switchedOff.isEmpty { text += " · выключено: \(summary.switchedOff.count)" }
            flash(text)
        }
    }

    // MARK: subscriptions

    /// One entry point for whatever the user pastes: a subscription (also wrapped in another client's import link),
    /// or a single server.
    func addSource(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        switch SubscriptionLink.classify(t) {
        case .subscription(let url):
            if subscriptions.contains(where: { $0.url == url }) { return "Эта подписка уже добавлена" }
            let e = SubscriptionEntry(url: url)
            subscriptions.append(e)
            SubscriptionStore.save(subscriptions, to: engine.supportDirectory)
            Task { await refreshSubscription(e.id) }
            return nil
        case .encrypted:
            return "Это зашифрованная ссылка Happ — открыть её может только Happ. Возьмите у провайдера обычную ссылку подписки (https://…)."
        case .insecure:
            return "Нужна защищённая ссылка https:// — по http подписка передаётся в открытом виде."
        case .notASubscription:
            return addServer(link: t)
        }
    }

    func refreshSubscription(_ id: String, quiet: Bool = false) async {
        guard subscriptions.contains(where: { $0.id == id }), !subscriptionBusy.contains(id) else { return }
        subscriptionBusy.insert(id)
        defer { subscriptionBusy.remove(id) }
        let url = subscriptions.first { $0.id == id }!.url, s = engine.settings
        let socks: (String, UInt16)? = upstreamOK ? (s.upstreamHost, s.upstreamPort) : nil
        var result: Subscription.FetchResult?
        var failure: String?
        do { result = try await Subscription.fetch(url, socks: socks) }
        catch {
            failure = "\(error)"
            // Through the VPN failed (provider may refuse VPN exits): one more try directly.
            if socks != nil, let r = try? await Subscription.fetch(url, socks: nil) { result = r; failure = nil }
        }
        guard let j = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        if let r = result {
            let before = Set(servers.filter { $0.source == id }.map(\.link))
            servers = Subscription.merge(existing: servers, subscription: id, fresh: r.parsed.servers, region: engine.settings.region)
            ServerStore.save(servers, to: engine.supportDirectory)
            subscriptions[j].updated = Date()
            subscriptions[j].error = nil
            subscriptions[j].servers = r.parsed.servers.count
            subscriptions[j].skipped = r.parsed.skippedCount
            subscriptions[j].skippedReasons = r.parsed.skipped.sorted { $0.value > $1.value }.map { "\($0.key) — \($0.value)" }
            subscriptions[j].info = r.info
            subscriptions[j].updateHours = r.updateHours
            if let t = r.title { subscriptions[j].title = t }
            let changed = before != Set(servers.filter { $0.source == id }.map(\.link))
            if !quiet { flash("«\(subscriptions[j].name)»: \(plural(r.parsed.servers.count, "сервер", "сервера", "серверов")) — проверяю…") }
            else if changed { flash("Подписка «\(subscriptions[j].name)» обновилась: серверов \(r.parsed.servers.count)") }
            let unchecked = Set(servers.filter { $0.source == id && $0.checked == nil }.map(\.id))
            if !unchecked.isEmpty { Task { await auditServers(ids: unchecked) } }
        } else {
            subscriptions[j].error = failure
        }
        SubscriptionStore.save(subscriptions, to: engine.supportDirectory)
    }

    /// Downloads every subscription that is due (default: hourly, see Settings). A failed attempt is not repeated for 10 minutes.
    func refreshStaleSubscriptions() async {
        let hours = settings.subscriptionHours ?? 1
        for sub in subscriptions where sub.isStale(hours: hours) {
            if let t = lastSubscriptionAttempt[sub.id], Date().timeIntervalSince(t) < 600 { continue }
            lastSubscriptionAttempt[sub.id] = Date()
            await refreshSubscription(sub.id, quiet: true)
        }
    }

    func removeSubscription(_ id: String) {
        servers.removeAll { $0.source == id }
        subscriptions.removeAll { $0.id == id }
        ServerStore.save(servers, to: engine.supportDirectory)
        SubscriptionStore.save(subscriptions, to: engine.supportDirectory)
    }

    /// Latency of each enabled server, measured through that server by the running tunnel.
    func testServers(_ ids: [String]) async {
        guard let api else { flash("Скорость можно проверить, когда включены «Все приложения»"); return }
        serverTesting = true
        defer { serverTesting = false }
        let tags = Dictionary(ServerStore.outbounds(servers).map { ($0.entry.id, $0.tag) }, uniquingKeysWith: { a, _ in a })
        await withTaskGroup(of: (String, Int?).self) { g in
            for id in ids { if let tag = tags[id] { g.addTask { (id, await api.delay(of: tag, url: PoolClass.general.testURL)) } } }
            for await (id, ms) in g {
                if let ms { serverDelays[id] = ms; serverDelayFailed.remove(id) } else { serverDelays[id] = nil; serverDelayFailed.insert(id) }
            }
        }
    }

    // MARK: community lists

    func updateCommunityLists(silent: Bool = false) async {
        communityBusy = true; defer { communityBusy = false }
        let s = engine.settings
        let r = await CommunityListUpdater.refresh(home: engine.supportDirectory, socks: upstreamOK ? (s.upstreamHost, s.upstreamPort) : nil)
        communityMessage = r.summary
        communityInstalled = Set(CommunityListUpdater.installed(home: engine.supportDirectory).map(\.id))
        if !silent { flash("Списки: \(r.summary)") }
    }

    func removeCommunityLists() {
        try? FileManager.default.removeItem(at: CommunityListUpdater.listsDirectory(engine.supportDirectory))
        communityInstalled = []; communityMessage = "списки удалены"
    }

    // MARK: diagnostics

    func runDiagnostics() {
        guard !diagRunning else { return }
        diagRunning = true; diag = []
        Task {
            let extra = [autostartCheck()]
            let result = await Diagnostics.run(engine: engine, tunnel: TunnelStatus.read(), extra: extra) { c in Task { @MainActor in self.diag.append(c) } }
            diag = result; diagAt = Date(); diagRunning = false
        }
    }

    private func autostartCheck() -> DiagCheck {
        let login = SMAppService.mainApp.status == .enabled
        let vpn = settings.autoStartVPN ?? true
        return DiagCheck(id: "autostart", title: "Автозапуск", status: login ? .ok : .warn,
                         detail: "Waypoint при входе: \(login ? "да" : "нет"); VPN-клиент вместе с Waypoint: \(vpn ? "да" : "нет"); демон туннеля: при загрузке системы",
                         hint: login ? nil : "Включите «Запускать при входе» в настройках.")
    }

    var diagnosticsReport: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Waypoint — отчёт диагностики \(f.string(from: diagAt ?? Date()))\n\n" + diag.map { c in
            "[\(c.status.rawValue.uppercased())] \(c.title)\n\(c.detail)" + (c.hint.map { "\n→ \($0)" } ?? "")
        }.joined(separator: "\n\n")
    }

    // MARK: launch at login, backup

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { flash("Автозапуск: \(error.localizedDescription) (работает для приложения в /Applications или ~/Applications)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func exportBackup() {
        let p = NSSavePanel(); p.nameFieldStringValue = "waypoint-backup.json"; p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try Backup.export(home: engine.supportDirectory, to: url); flash("Копия сохранена") } catch { flash("Не удалось: \(error.localizedDescription)") }
    }

    func importBackup() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let msg = try Backup.restore(from: url, home: engine.supportDirectory)
            settings = AppSettings.load(from: engine.supportDirectory)
            engine.rules.setManualRules(ManualRule.parseAll((try? String(contentsOf: engine.supportDirectory.appendingPathComponent("rules.txt"), encoding: .utf8)) ?? ""), persist: false)
            engine.rules.configure(settings: settings)
            manualText = ManualRule.serialize(engine.rules.manual); servers = ServerStore.load(from: engine.supportDirectory); subscriptions = SubscriptionStore.load(from: engine.supportDirectory); syncAppRoutes()
            connectionRules = ConnectionRuleStore.load(from: engine.supportDirectory)
            flash("Восстановлено — \(msg)")
        } catch { flash("Не удалось: \(error.localizedDescription)") }
    }

    func finishOnboarding() { applySettings { $0.onboardingDone = true }; showOnboarding = false }

    // MARK: "current site" (menu popover)

    func refreshCurrentSite() {
        currentHost = nil
        guard let id = lastBrowser, let src = Browsers.scripts[id], !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { return }
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue
        if err != nil { flash("Нет доступа к браузеру: разрешите Waypoint в Настройки → Конфиденциальность → Автоматизация"); return }
        if let out, let host = URL(string: out)?.host, !host.isEmpty { currentHost = host }
        refreshCurrentDecision()
    }

    func refreshCurrentDecision() {
        guard let h = currentHost else { currentDecision = nil; currentIsPinned = nil; return }
        currentDecision = engine.rules.decide(host: h, port: 443)
        let key = registrableDomain(h)
        currentIsPinned = engine.rules.manual.first { $0.value == key && ($0.kind == .suffix || $0.kind == .exact) }?.route
    }

    // MARK: apps

    nonisolated static func scanApps() -> [AppInfo] {
        let fm = FileManager.default
        var dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", NSHomeDirectory() + "/Applications"]
        dirs = dirs.filter { fm.fileExists(atPath: $0) }
        var out: [AppInfo] = []
        for d in dirs {
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where n.hasSuffix(".app") {
                let path = d + "/" + n
                guard AppPath.isValid(path) else { continue }       // skips Waypoint / Happ (reserved) and odd names
                var uses = 0
                if let item = MDItemCreate(kCFAllocatorDefault, path as CFString), let v = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? Int { uses = v }
                out.append(AppInfo(path: path, name: String(n.dropLast(4)), uses: uses))
            }
        }
        return out.sorted { $0.uses != $1.uses ? $0.uses > $1.uses : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: navigation (System Settings style back / forward)

    func go(_ s: Screen) {
        guard s != screen else { return }
        backStack.append(screen); forwardStack.removeAll(); screen = s
    }
    func goBack() { guard let s = backStack.popLast() else { return }; forwardStack.append(screen); screen = s }
    func goForward() { guard let s = forwardStack.popLast() else { return }; backStack.append(screen); screen = s }

    // MARK: exit country

    /// Which country websites see — directly and through the VPN. Cheap (Cloudflare trace), refreshed at most every 5 minutes.
    func refreshExitCountry(force: Bool = false) {
        guard force || Date().timeIntervalSince(exitCheckedAt) > 300 else { return }
        exitCheckedAt = Date()
        let phys = engine.network.physical, s = engine.settings
        Task {
            async let d = Probe.httpsGet(host: "www.cloudflare.com", path: "/cdn-cgi/trace", via: .direct(phys), timeoutMs: 8000)
            async let v = Probe.httpsGet(host: "www.cloudflare.com", path: "/cdn-cgi/trace", via: .socks(host: s.upstreamHost, port: s.upstreamPort), timeoutMs: 8000)
            let (dr, vr) = await (d, v)
            exitDirect = (try? dr.get()).flatMap { Diagnostics.cloudflareLoc($0.text) }
            exitVPN = (try? vr.get()).flatMap { Diagnostics.cloudflareLoc($0.text) }
        }
    }

    static func flag(_ code: String?) -> String {
        guard let code, code.count == 2 else { return "🌐" }
        return String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }
    static func countryName(_ code: String?) -> String {
        guard let code else { return "—" }
        // Short everyday names where the official one does not fit a tile or a status line.
        let short = ["US": "США", "GB": "Великобритания", "AE": "ОАЭ", "KR": "Южная Корея", "CZ": "Чехия", "NL": "Нидерланды"]
        return short[code.uppercased()] ?? Locale(identifier: "ru_RU").localizedString(forRegionCode: code) ?? code
    }

    /// The VPN client's own app (for its icon), if we know it.
    var vpnAppPath: String? {
        guard let name = settings.vpnServiceName, let bid = VPNLauncher.bundleIDs[name] else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)?.path
    }

    // MARK: sites (manual domain rules)

    var siteRules: [ManualRule] { engine.rules.manual.filter { $0.kind != .app } }

    func addSite(_ text: String, route: Route) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let host = URL(string: t.contains("://") ? t : "https://" + t)?.host ?? t
        guard let rule = ManualRule.parse("\(route.rawValue) \(host)") else { return false }
        var rules = engine.rules.manual.filter { !($0.kind == rule.kind && $0.value == rule.value) }
        rules.append(rule)
        engine.rules.setManualRules(rules)
        if rule.kind == .suffix { engine.rules.forget(domain: rule.value) }
        manualText = ManualRule.serialize(engine.rules.manual); learned = engine.rules.learnedEntries
        return true
    }

    func setSiteRoute(_ rule: ManualRule, _ route: Route) {
        let rules = engine.rules.manual.map { $0 == rule ? ManualRule(route: route, kind: $0.kind, value: $0.value) : $0 }
        engine.rules.setManualRules(rules); manualText = ManualRule.serialize(engine.rules.manual)
    }

    func removeRule(_ rule: ManualRule) {
        engine.rules.setManualRules(engine.rules.manual.filter { $0 != rule })
        manualText = ManualRule.serialize(engine.rules.manual); syncAppRoutes()
    }

    // MARK: preview data

    private func loadPreviewData() {
        func ev(_ h: String, _ r: String, _ s: String, _ n: String, _ ms: Int, _ ago: Double) -> RouteEvent {
            RouteEvent(time: Date().addingTimeInterval(-ago), host: h, port: 443, route: r, source: s, note: n, ms: ms)
        }
        running = true; upstreamOK = true; vpnState = "Connected"; interfaceName = "en0"; proxyIgnored = true
        settings.vpnServiceName = "Happ"; vpnServices = ["Happ"]; settings.playbooks = ["tiktok", "strict-ru"]
        tunnelWanted = true
        tunnel = TunnelStatus(state: .running, message: "туннель работает (самотест 91 мс)", physical: "en0", vpn: "utun7", updated: Date(), notes: nil, retryAt: nil, servers: 0, lists: 8)
        events = [ev("www.bbc.com", "vpn", "race", "гонка: vpn за 1147 мс; напрямую: молчит; выучено → VPN", 1150, 2), ev("github.com", "direct", "race", "гонка: direct за 107 мс", 108, 3),
                  ev("www.tiktok.com", "vpn", "manual", "", 0, 6), ev("yandex.ru", "direct", "starter", "", 25, 8), ev("dead.example", "failed", "race", "недоступен на обоих путях", 5003, 12)]
        let now = Date()
        func c(_ id: String, _ host: String, _ app: String?, _ chain: [String], _ up: UInt64, _ down: UInt64, _ age: Double) -> LiveConnection {
            LiveConnection(id: id, host: host, port: 443, network: "tcp", processPath: app, chain: chain, rule: "", upload: up, download: down, start: now.addingTimeInterval(-age))
        }
        connections = [
            c("1", "www.tiktok.com", "/Applications/Comet.app/Contents/MacOS/Comet", ["via-happ", "pool-video"], 24_000, 3_400_000, 42),
            c("2", "v16-webapp.tiktokcdn.com", "/Applications/Comet.app/Contents/MacOS/Comet", ["via-happ", "pool-video"], 8_000, 18_200_000, 31),
            c("3", "yandex.ru", "/Applications/Comet.app/Contents/MacOS/Comet", ["direct-phys"], 4_000, 210_000, 20),
            c("4", "gateway.discord.gg", "/Applications/Cursor.app/Contents/MacOS/Cursor", ["via-happ", "pool-chat"], 2_000, 5_000, 300),
            c("5", "api.anthropic.com", "/Applications/Claude.app/Contents/MacOS/Claude", ["via-happ", "pool-ai"], 51_000, 140_000, 90),
            c("6", "github.com", "/usr/bin/git", ["waypoint-race"], 1_200, 96_000, 8),
        ]
        traffic = TrafficStats(byApp: ["/Applications/Comet.app": .init(direct: 41_000_000, vpn: 212_000_000), "/Applications/Cursor.app": .init(direct: 8_000_000, vpn: 3_000_000),
                                       "/Applications/Claude.app": .init(direct: 100_000, vpn: 12_000_000), "/usr/bin/git": .init(direct: 24_000_000, vpn: 0)],
                               total: .init(direct: 73_000_000, vpn: 227_000_000), upRate: 84_000, downRate: 3_200_000)
        history = (0..<60).map { i in TrafficPoint(t: now.addingTimeInterval(Double(i - 60)), up: Double.random(in: 10_000...120_000), down: 2_000_000 + 1_500_000 * sin(Double(i) / 6) + Double.random(in: 0...400_000)) }
        currentHost = "www.tiktok.com"; currentDecision = Decision(.vpn, .manual, allowFallback: true)
        installedApps = [AppInfo(path: "/Applications/Comet.app", name: "Comet", uses: 2379), AppInfo(path: "/Applications/Cursor.app", name: "Cursor", uses: 41),
                         AppInfo(path: "/Applications/Claude.app", name: "Claude", uses: 41), AppInfo(path: "/Applications/Obsidian.app", name: "Obsidian", uses: 23)]
        appRoutes = ["/Applications/Cursor.app": .vpn]
        communityInstalled = Set(CommunityList.all.prefix(8).map(\.id))
        diag = [DiagCheck(id: "net", title: "Физическая сеть и DNS", status: .ok, detail: "en0: прямое соединение с DNS-разрешением за 95 мс"),
                DiagCheck(id: "egress", title: "Страна выхода", status: .ok, detail: "напрямую: RU, через VPN: DE"),
                DiagCheck(id: "tiktok", title: "TikTok: свежая лента", status: .ok, detail: "решение Waypoint: VPN\nнапрямую: полный сайт, регион RU\nчерез VPN: полный сайт, регион DE\nчерез туннель (как обычное приложение): полный сайт, регион DE\nитог: регион DE — не Россия, лента будет свежей"),
                DiagCheck(id: "discord", title: "Discord", status: .warn, detail: "чат/API → через VPN; голос (UDP) → напрямую", hint: "Голос идёт по UDP без имени сайта: включите сценарий «Голос, звонки и игры».")]
        diagAt = Date(); learned = [LearnedEntry(domain: "rutracker.org", learnedAt: Date().addingTimeInterval(-3600), lastConfirmed: Date(), hits: 2), LearnedEntry(domain: "bbc.com", learnedAt: Date().addingTimeInterval(-7200), lastConfirmed: Date(), hits: 3)]
        exitDirect = "RU"; exitVPN = "DE"
        var sub = SubscriptionEntry(id: "S1", url: "https://sub.example.com/api/sub/abc")
        sub.title = "Мой провайдер"; sub.updated = Date().addingTimeInterval(-1800); sub.servers = 4; sub.skipped = 1
        sub.info = SubscriptionInfo(upload: 2_000_000_000, download: 38_000_000_000, total: 200_000_000_000, expire: Date().addingTimeInterval(86400 * 23))
        subscriptions = [sub]
        servers = [ServerEntry(id: "a", name: "🇩🇪 Германия", link: "trojan://p@de.example.com:443#DE", source: "S1"),
                   ServerEntry(id: "b", name: "🇳🇱 Нидерланды", link: "trojan://p@nl.example.com:443#NL", source: "S1"),
                   ServerEntry(id: "c", name: "🇹🇷 Турция", link: "trojan://p@tr.example.com:443#TR", source: "S1"),
                   ServerEntry(id: "d", name: "🇷🇺 Россия", link: "trojan://p@ru.example.com:443#RU", enabled: false, source: "S1")]
        serverDelays = ["a": 84, "b": 97, "c": 143]
    }
}

/// Browsers whose front tab we can read (AppleScript) to offer "route this site".
enum Browsers {
    static let scripts: [String: String] = [
        "com.apple.Safari": "tell application id \"com.apple.Safari\" to return URL of current tab of front window",
        "com.google.Chrome": "tell application id \"com.google.Chrome\" to return URL of active tab of front window",
        "com.brave.Browser": "tell application id \"com.brave.Browser\" to return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application id \"com.microsoft.edgemac\" to return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application id \"company.thebrowser.Browser\" to return URL of active tab of front window",
        "com.vivaldi.Vivaldi": "tell application id \"com.vivaldi.Vivaldi\" to return URL of active tab of front window",
        "ai.perplexity.comet": "tell application id \"ai.perplexity.comet\" to return URL of active tab of front window",
    ]
}
