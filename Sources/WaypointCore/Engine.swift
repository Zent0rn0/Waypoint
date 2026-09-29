import Foundation
import Network
import os

// MARK: - Events & stats

public struct RouteEvent: Identifiable, Sendable {
    public let id = UUID()
    public let time: Date
    public let host: String
    public let port: UInt16
    /// "direct", "vpn", "block" or "failed"
    public let route: String
    /// Why that route: manual / learned / starter / local / race
    public let source: String
    public let note: String
    public let ms: Int

    public init(time: Date, host: String, port: UInt16, route: String, source: String, note: String, ms: Int) {
        self.time = time; self.host = host; self.port = port; self.route = route
        self.source = source; self.note = note; self.ms = ms
    }
}

public struct Stats: Sendable, Equatable {
    public var directBytes: UInt64 = 0
    public var vpnBytes: UInt64 = 0
    public var active = 0
    public var total = 0
    public init() {}
}

// MARK: - Engine

/// Owns the listener, the rules, the dialers and the learning loop. One instance per process.
public final class Engine: @unchecked Sendable {
    public let rules: RuleEngine
    public let network = NetworkMonitor()
    public let supportDirectory: URL

    private let lock = NSLock()
    private var _settings: AppSettings
    private var server: ProxyServer?
    private var idleTask: Task<Void, Never>?
    private var revalTask: Task<Void, Never>?
    private var revalidating = Set<String>()
    private var ring: [RouteEvent] = []
    private let statsLock = OSAllocatedUnfairLock(initialState: Stats())
    private var vpnActive = 0
    private var lastVPNUse = Date()
    private var weStartedVPN = false
    private var directLatencyEWMA: Double?     // ms, first-byte time of successful direct races

    public var onEvent: (@Sendable (RouteEvent) -> Void)?
    public var onLearned: (@Sendable (LearnedEntry) -> Void)? {
        didSet { rules.onLearned = onLearned }
    }

    public init(settings: AppSettings = AppSettings.load(), supportDirectory: URL = AppSettings.supportDirectory) {
        self._settings = settings
        self.supportDirectory = supportDirectory
        self.rules = RuleEngine(directory: supportDirectory, region: settings.region)
        self.rules.configure(settings: settings)
    }

    public var settings: AppSettings { lock.lock(); defer { lock.unlock() }; return _settings }
    public var stats: Stats { statsLock.withLock { $0 } }
    public var recentEvents: [RouteEvent] { lock.lock(); defer { lock.unlock() }; return ring }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return server != nil }

    public func update(_ change: (inout AppSettings) -> Void) {
        lock.lock()
        change(&_settings)
        let s = _settings
        lock.unlock()
        rules.configure(settings: s)
        s.save(to: supportDirectory)
    }

    // MARK: lifecycle

    public func start() async throws {
        if isRunning { return }
        network.start()
        // Without this, connections accepted in the first moments would be dialed unpinned (into the VPN tunnel).
        for _ in 0..<20 where network.physical == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        let s = ProxyServer(engine: self)
        try await s.start(port: settings.listenPort)
        lock.withLock { server = s }
        startIdleWatcher()
        startRevalidationLoop()
    }

    public func stop() {
        lock.lock(); let s = server; server = nil; lock.unlock()
        s?.stop()
        idleTask?.cancel()
        revalTask?.cancel()
        network.stop()
    }

    // MARK: dialing

    private var directDialer: DirectDialer { DirectDialer(interface: { [network] in network.physical }) }

    private var upstreamDialer: UpstreamDialer {
        let s = settings
        var d = UpstreamDialer(host: s.upstreamHost, port: s.upstreamPort)
        if s.onDemandVPN, let name = s.vpnServiceName {
            d.prepare = { [weak self] in
                guard let self else { return }
                let wasOn = VPNController.isConnected(name)
                let ok = await VPNController.ensureConnected(name) {
                    await UpstreamProbe.isOpenSocks5(host: s.upstreamHost, port: s.upstreamPort, timeoutMs: 800)
                }
                if ok && !wasOn { self.lock.withLock { self.weStartedVPN = true } }
            }
        }
        return d
    }

    /// The hedge delay adapts to how fast the direct path really is: on a slow link (hotel Wi‑Fi, tethering)
    /// a healthy site must not be mistaken for a blocked one just because it answers in 1.2 s.
    var racer: Racer {
        var cfg = settings.race.config
        if let e = lock.withLock({ directLatencyEWMA }) { cfg.hedgeMs = max(cfg.hedgeMs, min(3000, Int(e * 3))) }
        return Racer(direct: directDialer, vpn: upstreamDialer, config: cfg)
    }

    func noteDirectLatency(ms: Int) {
        lock.withLock { directLatencyEWMA = directLatencyEWMA.map { $0 * 0.8 + Double(ms) * 0.2 } ?? Double(ms) }
    }

    func dial(_ kind: PathKind, host: String, port: UInt16) async throws -> NWConnection {
        let s = settings
        switch kind {
        case .direct:
            return try await withTimeout(ms: s.race.directDeadlineMs) { [self] in
                try await directDialer.dial(host: host, port: port, deadlineMs: s.race.directDeadlineMs)
            }
        case .vpn:
            return try await withTimeout(ms: s.race.vpnDeadlineMs + (s.onDemandVPN ? 15000 : 0)) { [self] in
                try await upstreamDialer.dial(host: host, port: port, deadlineMs: s.race.vpnDeadlineMs)
            }
        }
    }

    // MARK: accounting

    func connectionOpened() { statsLock.withLock { $0.active += 1; $0.total += 1 } }
    func connectionClosed() { statsLock.withLock { $0.active -= 1 } }
    func addBytes(_ n: Int, path: PathKind) {
        statsLock.withLock { if path == .direct { $0.directBytes += UInt64(n) } else { $0.vpnBytes += UInt64(n) } }
    }

    func vpnBegin() { lock.lock(); vpnActive += 1; lastVPNUse = Date(); lock.unlock() }
    func vpnEnd() { lock.lock(); vpnActive -= 1; lastVPNUse = Date(); lock.unlock() }

    func emit(host: String, port: UInt16, route: String, source: String, note: String = "", started: Date) {
        let e = RouteEvent(time: Date(), host: host, port: port, route: route, source: source, note: note,
                           ms: Int(Date().timeIntervalSince(started) * 1000))
        lock.lock()
        ring.append(e)
        if ring.count > 300 { ring.removeFirst(ring.count - 300) }
        lock.unlock()
        onEvent?(e)
    }

    // MARK: on-demand VPN: stop it again when idle

    private func startIdleWatcher() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self else { return }
                let s = self.settings
                guard s.onDemandVPN, let name = s.vpnServiceName else { continue }
                let (idle, ours) = self.lock.withLock {
                    (self.vpnActive == 0 && Date().timeIntervalSince(self.lastVPNUse) > Double(s.idleDisconnectMinutes) * 60,
                     self.weStartedVPN)
                }
                // Only stop a VPN that *we* started; never kill a tunnel the user connected on purpose.
                if idle, ours, VPNController.isConnected(name) {
                    VPNController.stop(name)
                    self.lock.withLock { self.weStartedVPN = false }
                }
            }
        }
    }

    // MARK: second opinion + revalidation of learned verdicts

    /// "Second opinion" before a domain is learned as blocked: one fresh direct TLS handshake pinned to the physical NIC.
    /// A single stalled attempt (tunnel restarting, Wi‑Fi hiccup, a slow server) must not send a domain through the VPN for weeks.
    /// Only TLS ports can be re-probed this way; for others the original evidence stands.
    func confirmBlocked(host: String, port: UInt16) async -> Bool {
        guard FirstResponse.isTLSPort(port), !isIPLiteral(host) else { return true }
        if case .success = await Probe.tlsHandshake(host: host, port: port, path: .direct(network.physical), timeoutMs: 3000) { return false }
        return true
    }

    /// Learned domains are normally routed by the tunnel and never pass the racer again, so nothing would ever re-check them.
    /// This loop does: every couple of minutes a few stale ones get a direct probe — if it works now, the domain is forgotten.
    private func startRevalidationLoop() {
        revalTask?.cancel()
        revalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                let stale = self.rules.learnedEntries.filter { !isIPLiteral($0.domain.split(separator: "/").first.map(String.init) ?? $0.domain) && self.rules.needsRevalidation(host: $0.domain) }.prefix(6)
                for e in stale {
                    var ok = false
                    for candidate in [e.domain, "www." + e.domain] {
                        if case .success = await Probe.tlsHandshake(host: candidate, path: .direct(self.network.physical), timeoutMs: 4000) { ok = true; break }
                    }
                    if ok { self.rules.forget(domain: e.domain) } else { self.rules.markConfirmed(host: e.domain) }
                }
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            }
        }
    }

    // MARK: revalidation of learned verdicts (per use, in PAC mode)

    /// If a learned "vpn" verdict is stale, check in the background whether the direct path works again
    /// (block lifted, or you are on another network / in another country). If it does, forget the verdict.
    func revalidateIfNeeded(host: String) {
        guard rules.needsRevalidation(host: host) else { return }
        let key = registrableDomain(host)
        lock.lock()
        let inserted = revalidating.insert(key).inserted
        lock.unlock()
        guard inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            let r = await Probe.tlsHandshake(host: host, path: .direct(self.network.physical), timeoutMs: 4000)
            if case .success = r { self.rules.forget(domain: key) } else { self.rules.markConfirmed(host: host) }
            _ = self.lock.withLock { self.revalidating.remove(key) }
        }
    }
}
