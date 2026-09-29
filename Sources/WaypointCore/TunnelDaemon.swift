import Foundation
import Network
import Security

/// What the root daemon reports; the (unprivileged) app only ever *reads* this, from a root-owned directory.
public struct TunnelStatus: Codable, Equatable {
    public enum State: String, Codable { case off, waiting, starting, running, error }
    public var state: State
    public var message: String
    public var physical: String?
    public var vpn: String?
    public var updated: Date
    /// Features that were switched off automatically (bad server link, unusable list …) so the tunnel could still start.
    public var notes: [String]?
    public var retryAt: Date?
    public var servers: Int?
    public var lists: Int?
    public init(state: State, message: String, physical: String?, vpn: String?, updated: Date, notes: [String]? = nil, retryAt: Date? = nil, servers: Int? = nil, lists: Int? = nil) {
        self.state = state; self.message = message; self.physical = physical; self.vpn = vpn; self.updated = updated
        self.notes = notes; self.retryAt = retryAt; self.servers = servers; self.lists = lists
    }
    public static let defaultPath = "/var/db/waypoint/status.json"
    public static let apiPath = "/var/db/waypoint/api.json"

    public static func read(path: String = defaultPath) -> TunnelStatus? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(TunnelStatus.self, from: d)
    }
}

/// Where the local sing-box API listens (root writes it, readable only by the owner of the Waypoint data dir).
public struct TunnelAPIInfo: Codable, Equatable {
    public var port: UInt16
    public var secret: String
    public static func read(path: String = TunnelStatus.apiPath) -> TunnelAPIInfo? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(TunnelAPIInfo.self, from: d)
    }
}

/// Supervises sing-box (TUN "tunnel mode"). Design rules:
///  • **Fail open.** Anything wrong (VPN down, racer gone, self-test fails, sing-box crashes) → sing-box is stopped and the
///    TUN disappears with it, so traffic simply takes the normal path again.
///  • **Off by default.** It only runs while the user's flag file `<home>/tunnel.enabled` exists.
///  • **Least trust.** As root it only *reads* user files (settings, rules, servers, lists); it writes only under its own
///    root-owned state dir, and only validated tokens end up in the generated config. Every config is pre-flighted with
///    `sing-box check`; a server link or list that breaks it is dropped instead of taking the tunnel down.
///  • **Network-aware breaker.** A failing self-test only counts against the tunnel if the *physical* network is fine
///    (sleep/wake, Wi‑Fi roaming and captive portals must not disable it). After a real failure it retries by itself
///    (1 min, 5 min, 30 min) before giving up.
public final class TunnelDaemon {
    public struct Options {
        public var home: URL             // the user's Waypoint support dir
        public var singBox: URL
        public var state: URL            // root-owned working dir (config, rulesets, cache, log, status)
        public var tun = true            // false: local mixed inbound instead of a TUN (for testing without root)
        public var mixedPort: UInt16 = 7811
        public var apiPort: UInt16 = 9097
        public init(home: URL, singBox: URL, state: URL, tun: Bool = true, mixedPort: UInt16 = 7811, apiPort: UInt16 = 9097) {
            self.home = home; self.singBox = singBox; self.state = state; self.tun = tun; self.mixedPort = mixedPort; self.apiPort = apiPort
        }
    }

    private let o: Options
    private let queue = DispatchQueue(label: "waypoint.daemon")
    private let network = NetworkMonitor()
    private var timer: DispatchSourceTimer?
    /// sing-box is started through /bin/sh (see `launch`), so it is not our child: supervise it by pid.
    private var childPID: pid_t?
    private var childRunning: Bool { childPID.map { kill($0, 0) == 0 } ?? false }
    private var structuralKey = ""
    private var startedAt = Date.distantPast
    private var lastHealth = Date.distantPast
    private var healthFailures = 0
    private var crashes: [Date] = []
    private var rules: RuleEngine?
    private var inputStamp = ""
    private var ticking = false
    private var flagWasPresent = false
    private var lastError: String?
    private var trips = 0
    private var cooldownUntil: Date?
    private var notes: [String] = []
    private var serverCount = 0
    private var listCount = 0
    private var apiSecret: String = ""

    public init(_ options: Options) { o = options }

    private var flagURL: URL { o.home.appendingPathComponent("tunnel.enabled") }
    private var statusURL: URL { o.state.appendingPathComponent("status.json") }
    private var ruleDir: URL { o.state.appendingPathComponent("rulesets", isDirectory: true) }
    private static let retryDelays: [TimeInterval] = [60, 300, 1800]

    public func run() -> Never {
        try? FileManager.default.createDirectory(at: ruleDir, withIntermediateDirectories: true)
        apiSecret = Self.randomHex(16)
        writeAPIInfo()
        network.start()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            s.setEventHandler { [weak self] in self?.stopChild(); self?.publish(.off, "демон остановлен"); exit(0) }
            s.resume(); Self.signalSources.append(s)
        }
        publish(.off, "демон запущен, туннель выключен")
        dispatchMain()
    }
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    static func randomHex(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    /// The API secret file lives in the root-owned state dir (no symlink games with user-writable paths) and is
    /// handed to the owner of the data dir with mode 0600.
    private func writeAPIInfo() {
        let path = o.state.appendingPathComponent("api.json").path
        unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let json = "{\"port\":\(o.apiPort),\"secret\":\"\(apiSecret)\"}"
        _ = json.withCString { write(fd, $0, strlen($0)) }
        if let uid = (try? FileManager.default.attributesOfItem(atPath: o.home.path))?[.ownerAccountID] as? NSNumber, uid.intValue != 0 {
            fchown(fd, uid_t(uid.intValue), gid_t(20))
        }
    }

    // MARK: tick

    private func tick() {
        guard !ticking else { return }
        ticking = true
        Task { [self] in
            await evaluate()
            queue.async { self.ticking = false }
        }
    }

    private func evaluate() async {
        if let pid = childPID, kill(pid, 0) != 0 { childPID = nil; crashes.append(Date()) }        // died on its own
        let enabled = FileManager.default.fileExists(atPath: flagURL.path)
        if enabled && !flagWasPresent { trips = 0; cooldownUntil = nil; lastError = nil }     // the user switched it on again: fresh start
        flagWasPresent = enabled
        guard enabled else {
            if childPID != nil { stopChild() }
            // Keep an emergency shutdown visible until the user switches the tunnel on again.
            if let e = lastError { publish(.error, e) } else { publish(.off, "туннель выключен") }
            return
        }
        if let until = cooldownUntil, until > Date() {
            if childPID != nil { stopChild() }
            publish(.error, lastError ?? "пауза после сбоя", retryAt: until); return
        }
        cooldownUntil = nil

        let settings = AppSettings.load(from: o.home)
        guard let phys = network.physical?.name else { stopChild(); publish(.waiting, "нет физического интерфейса (Wi‑Fi/Ethernet)"); return }
        guard let vpnName = settings.vpnServiceName, let svc = VPNController.service(named: vpnName), svc.isConnected,
              let vpnIf = NetworkFacts.vpnInterface(serviceID: svc.id) else {
            stopChild(); publish(.waiting, "VPN-клиент не подключён — туннель не запускается, сеть работает как обычно", physical: phys); return
        }
        guard await Probe.tcpOpen(host: "127.0.0.1", port: settings.listenPort) else {
            stopChild(); publish(.waiting, "не запущен Waypoint (гоночный прокси на порту \(settings.listenPort)) — туннель выключен, сеть как обычно", physical: phys, vpn: vpnIf); return
        }

        let dns = NetworkFacts.directDNS(interface: phys)
        refreshRules(settings)
        guard let rules else { return }
        let policy = rules.currentPolicy
        let outs = ServerStore.outbounds(ServerStore.load(from: o.home))
        let servers = outs.map { (tag: $0.tag, server: $0.parsed) }
        let conn = ConnectionPlan.build(ConnectionRuleStore.load(from: o.home), servers: outs.map { (tag: $0.tag, id: $0.entry.id) })
        let community = settings.communityLists == true ? syncCommunityLists() : []
        let stack = settings.tunnelStack ?? "gvisor", level = settings.tunnelLogLevel ?? "warn"
        let key = [phys, vpnIf, dns, String(settings.listenPort), String(o.tun), stack, level, policy.finalMode.rawValue, String(policy.udpViaVPN),
                   servers.map { "\($0.tag):\($0.server.host):\($0.server.port)" }.joined(separator: ","), community.map(\.id).joined(separator: ","),
                   conn.serverTags.joined(separator: ",")].joined(separator: "|")      // a new server as a target changes the structure
        writeRuleSets(rules: rules, policy: policy, connections: conn)

        if childRunning {
            if key != structuralKey { stopChild() }                    // Wi‑Fi ↔ Ethernet, VPN reconnected with another utun, servers/lists changed …
            else { await healthCheck(phys: phys, vpn: vpnIf); return }
        }
        if recentCrashes() >= 3 { trip("sing-box падает слишком часто. Лог: \(o.state.path)/sing-box.log"); return }
        await start(key: key, phys: phys, vpn: vpnIf, dns: dns, settings: settings, policy: policy, servers: servers, community: community,
                    connectionServers: conn.serverTags, stack: stack, level: level)
    }

    // MARK: rules / rule-sets / community lists

    private func refreshRules(_ s: AppSettings) {
        func stamp(_ n: String) -> String {
            let a = try? FileManager.default.attributesOfItem(atPath: o.home.appendingPathComponent(n).path)
            return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        let now = [stamp("learned.json"), stamp("rules.txt"), stamp("settings.json")].joined(separator: "|")
        if rules == nil || now != inputStamp {
            let r = RuleEngine(directory: o.home, region: s.region)
            r.configure(settings: s)
            rules = r; inputStamp = now
        }
    }

    private func writeRuleSets(rules: RuleEngine, policy: CompiledPolicy, connections: ConnectionPlan) {
        for (name, data) in TunnelConfig.ruleSets(rules: rules, policy: policy, connections: connections) {
            let url = ruleDir.appendingPathComponent("\(name).json")
            if (try? Data(contentsOf: url)) == data { continue }
            let tmp = ruleDir.appendingPathComponent(".\(name).tmp")
            try? data.write(to: tmp)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)     // atomic: sing-box reloads it on the fly
        }
    }

    /// Copies the user's downloaded lists into the root-owned dir after a format check. Returns the lists that are usable.
    private func syncCommunityLists() -> [CommunityList] {
        var usable: [CommunityList] = []
        let src = o.home.appendingPathComponent("lists", isDirectory: true)
        for l in CommunityList.all {
            let from = src.appendingPathComponent(l.file), to = ruleDir.appendingPathComponent(l.file)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: from.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.intValue, size > 8, size < 32 * 1024 * 1024,
                  let data = try? Data(contentsOf: from), CommunityList.hasValidMagic(data) else { continue }
            if (try? Data(contentsOf: to)) != data {
                let tmp = ruleDir.appendingPathComponent(".\(l.file).tmp")
                try? data.write(to: tmp)
                _ = try? FileManager.default.replaceItemAt(to, withItemAt: tmp)
            }
            usable.append(l)
        }
        return usable
    }

    // MARK: start (with pre-flight)

    private func start(key: String, phys: String, vpn: String, dns: String, settings: AppSettings, policy: CompiledPolicy,
                       servers: [(tag: String, server: ParsedServer)], community: [CommunityList], connectionServers: [String],
                       stack: String, level: String) async {
        var p = TunnelParams(physicalInterface: phys, happInterface: vpn, racePort: settings.listenPort, directDNS: dns,
                             ruleSetDir: ruleDir.path, cachePath: o.state.appendingPathComponent("cache.db").path, tun: o.tun)
        p.mixedPort = o.mixedPort; p.apiPort = o.apiPort; p.stack = stack; p.logLevel = level; p.apiSecret = apiSecret
        let configURL = o.state.appendingPathComponent("config.json")

        // Full config first; if sing-box refuses it, shed the optional parts (bad server / bad list) instead of failing.
        var attempts: [(servers: [(tag: String, server: ParsedServer)], lists: [CommunityList], note: String?)] = [(servers, community, nil)]
        if !servers.isEmpty { attempts.append(([], community, "свои серверы отключены: конфиг с ними не прошёл проверку")) }
        if !community.isEmpty { attempts.append((servers, [], "списки сообщества отключены: конфиг с ними не прошёл проверку")) }
        if !servers.isEmpty && !community.isEmpty { attempts.append(([], [], "свои серверы и списки отключены: конфиг не прошёл проверку")) }

        var chosen: (servers: Int, lists: Int, notes: [String])?
        for a in attempts {
            guard let data = try? TunnelConfig.generate(p, policy: policy, servers: a.servers, community: a.lists, connectionServers: connectionServers) else { continue }
            try? data.write(to: configURL, options: .atomic)
            let singBox = o.singBox.path, cfg = configURL.path
            let r = await Task.detached { runProcess(singBox, ["check", "-c", cfg]) }.value
            if r.code == 0 {
                chosen = (a.servers.count, a.lists.count, a.note.map { [$0] } ?? [])
                break
            }
            notes = ["sing-box check: " + String((r.out + r.err).replacingOccurrences(of: "\n", with: " ").prefix(160))]
        }
        guard let ok = chosen else { trip("конфигурация не прошла проверку sing-box: \(notes.first ?? "")"); return }
        notes = ok.notes; serverCount = ok.servers; listCount = ok.lists

        rotateLog()
        if !FileManager.default.fileExists(atPath: o.state.appendingPathComponent("sing-box.log").path) {
            FileManager.default.createFile(atPath: o.state.appendingPathComponent("sing-box.log").path, contents: nil)
        }
        guard let pid = launch(config: configURL) else { trip("не удалось запустить sing-box"); return }
        childPID = pid; structuralKey = key; startedAt = Date(); healthFailures = 0; lastHealth = .distantPast
        publish(.starting, "запуск туннеля…", physical: phys, vpn: vpn)
    }

    private func rotateLog() {
        let url = o.state.appendingPathComponent("sing-box.log")
        if let s = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, s.intValue > 5 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func recentCrashes() -> Int { crashes.removeAll { Date().timeIntervalSince($0) > 60 }; return crashes.count }

    /// Starts sing-box detached through /bin/sh and returns its pid.
    ///
    /// Why not `Process` directly: on this macOS a process spawned by our own (ad-hoc signed) binary lost access to the kernel
    /// tables sing-box needs for per-application rules (it reported "process not found" and could not read the gateway MAC),
    /// while the same binary started via a system shell worked. Going through `sh` makes launchd the parent. Nothing user-controlled
    /// reaches the shell: paths are passed as positional arguments, never interpolated into the script.
    private func launch(config: URL) -> pid_t? {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "\"$1\" run -c \"$2\" -D \"$3\" >>\"$4\" 2>&1 </dev/null & echo $!", "waypoint-launch",
                        o.singBox.path, config.path, o.state.path, o.state.appendingPathComponent("sing-box.log").path]
        let out = Pipe()
        sh.standardOutput = out
        do { try sh.run() } catch { return nil }
        sh.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(text), pid > 1 else { return nil }
        return pid
    }

    private func stopChild() {
        guard let pid = childPID else { return }
        childPID = nil
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    // MARK: health — the whole chain (TUN → sing-box → racer → network) must work, or the tunnel is switched off

    private func healthCheck(phys: String, vpn: String) async {
        let since = Date().timeIntervalSince(startedAt)
        let interval: TimeInterval = healthFailures > 0 || since < 30 ? 2 : 20
        guard Date().timeIntervalSince(lastHealth) >= interval, since >= 2 else { return }
        lastHealth = Date()
        let path: Probe.Path = o.tun ? .direct(nil) : .socks(host: "127.0.0.1", port: o.mixedPort)
        let r = await Probe.tlsHandshake(host: "www.apple.com", path: path, timeoutMs: 4000)
        if case .success(let ms) = r {
            healthFailures = 0
            lastError = nil                                   // recovered: forget the old failure
            if since > 300 { trips = 0 }
            publish(.running, "туннель работает (самотест \(ms) мс)", physical: phys, vpn: vpn)
            return
        }
        // Is it the tunnel, or is the network itself gone (sleep/wake, roaming, captive portal)?
        if case .failure = await Probe.tlsHandshake(host: "www.apple.com", path: .direct(network.physical), timeoutMs: 4000) {
            healthFailures = 0
            publish(.waiting, "сеть недоступна — жду, туннель не трогаю", physical: phys, vpn: vpn)
            return
        }
        healthFailures += 1
        if healthFailures >= 3 { trip("самотест туннеля не прошёл 3 раза подряд при рабочей сети") }
    }

    /// The tunnel is misbehaving: stop it (traffic returns to the normal path) and retry later with growing pauses.
    private func trip(_ message: String) {
        stopChild()
        trips += 1
        if trips > Self.retryDelays.count {
            lastError = message + " — автоповторы исчерпаны, туннель выключен. Включите заново, когда причина устранена."
            try? FileManager.default.removeItem(at: flagURL)
            publish(.error, lastError!)
            return
        }
        let delay = Self.retryDelays[trips - 1]
        cooldownUntil = Date().addingTimeInterval(delay)
        lastError = message + " — сеть возвращена в обычное состояние, повтор через \(Int(delay / 60)) мин"
        publish(.error, lastError!, retryAt: cooldownUntil)
    }

    // MARK: status

    private var lastPublished: TunnelStatus?
    private func publish(_ state: TunnelStatus.State, _ message: String, physical: String? = nil, vpn: String? = nil, retryAt: Date? = nil) {
        var st = TunnelStatus(state: state, message: message, physical: physical, vpn: vpn, updated: Date(),
                              notes: notes.isEmpty ? nil : notes, retryAt: retryAt,
                              servers: state == .running || state == .starting ? serverCount : nil, lists: state == .running || state == .starting ? listCount : nil)
        if let l = lastPublished, l.state == st.state, l.message == st.message, l.physical == st.physical, l.notes == st.notes, Date().timeIntervalSince(l.updated) < 10 { return }
        lastPublished = st; st.updated = Date()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(st) {
            let tmp = o.state.appendingPathComponent(".status.tmp")
            try? d.write(to: tmp); try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path)
            _ = try? FileManager.default.replaceItemAt(statusURL, withItemAt: tmp)
        }
    }
}
