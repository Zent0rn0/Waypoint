import Foundation

// MARK: - Basic types

public enum Route: String, Codable, Sendable, CaseIterable {
    case direct, vpn, block
}

public struct Decision: Equatable, Sendable {
    public enum Action: String, Sendable { case direct, vpn, block, race }
    public enum Source: String, Sendable { case manual, learned, starter, local, unknown }
    public var action: Action
    public var source: Source
    /// If the chosen path fails to even connect, the session may try the other one.
    public var allowFallback: Bool

    public init(_ action: Action, _ source: Source, allowFallback: Bool = false) {
        self.action = action
        self.source = source
        self.allowFallback = allowFallback
    }
}

public enum Region: String, Codable, Sendable, CaseIterable {
    case none, russia
    public var title: String {
        switch self {
        case .none: return "Без стартовых списков (только автообучение)"
        case .russia: return "Россия"
        }
    }
}

// MARK: - Manual rules

/// One line of the user's rule file:  `vpn youtube.com`, `direct full:api.bank.ru`,
/// `vpn keyword:tiktok`, `direct cidr:10.0.0.0/8`, `block ads.example.com`. `*.` prefix = suffix rule.
public struct ManualRule: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case suffix, exact, keyword, cidr, app }
    public var route: Route
    public var kind: Kind
    public var value: String

    public var id: String { text }
    public var text: String {
        switch kind {
        case .suffix: return "\(route.rawValue) \(value)"
        case .exact: return "\(route.rawValue) full:\(value)"
        case .keyword: return "\(route.rawValue) keyword:\(value)"
        case .cidr: return "\(route.rawValue) cidr:\(value)"
        case .app: return "\(route.rawValue) app:\(value)"
        }
    }

    public init(route: Route, kind: Kind, value: String) {
        self.route = route
        self.kind = kind
        self.value = value
    }

    public static func parse(_ rawLine: String) -> ManualRule? {
        // A comment starts with '#' at the beginning or after whitespace (an app path may legitimately contain '#').
        var line = rawLine
        if line.hasPrefix("#") { return nil }
        if let r = line.range(of: " #") ?? line.range(of: "\t#") { line = String(line[..<r.lowerBound]) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let sp = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
              let route = Route(rawValue: trimmed[..<sp].lowercased()) else { return nil }
        var v = trimmed[sp...].trimmingCharacters(in: .whitespaces)

        if v.lowercased().hasPrefix("app:") {                                    // paths may contain spaces
            let path = String(v.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return AppPath.isValid(path) ? .init(route: route, kind: .app, value: AppPath.canonical(path)) : nil
        }
        guard !v.contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
        v = v.lowercased()
        if v.hasPrefix("full:") { return .init(route: route, kind: .exact, value: normalizeHost(String(v.dropFirst(5)))) }
        if v.hasPrefix("keyword:") { return .init(route: route, kind: .keyword, value: String(v.dropFirst(8))) }
        if v.hasPrefix("domain:") { v = String(v.dropFirst(7)) }
        if v.hasPrefix("cidr:") {
            let c = String(v.dropFirst(5))
            return IPv4CIDR(c) == nil ? nil : .init(route: route, kind: .cidr, value: c)
        }
        if v.hasPrefix("*.") { v = String(v.dropFirst(2)) }
        if v.hasPrefix(".") { v = String(v.dropFirst()) }
        guard !v.isEmpty else { return nil }
        if isIPLiteral(v) { return .init(route: route, kind: .exact, value: v) }
        return .init(route: route, kind: .suffix, value: normalizeHost(v))
    }

    public static func parseAll(_ text: String) -> [ManualRule] {
        text.split(whereSeparator: \.isNewline).compactMap { parse(String($0)) }
    }

    public static func serialize(_ rules: [ManualRule]) -> String {
        rules.map(\.text).joined(separator: "\n") + (rules.isEmpty ? "" : "\n")
    }
}

// MARK: - Learned verdicts

public struct LearnedEntry: Codable, Equatable, Sendable, Identifiable {
    public var domain: String
    public var learnedAt: Date
    public var lastConfirmed: Date
    public var hits: Int
    public var id: String { domain }
    public init(domain: String, learnedAt: Date, lastConfirmed: Date, hits: Int) {
        self.domain = domain; self.learnedAt = learnedAt; self.lastConfirmed = lastConfirmed; self.hits = hits
    }
}

// MARK: - Starter lists

public struct StarterLists: Sendable {
    public var vpn: DomainSet
    public var direct: DomainSet
    /// IPv4 ranges that must go through the VPN. Telegram's clients connect to bare IPs and speak MTProto on ports 80/443,
    /// so neither a name nor a TLS/HTTP handshake ever identifies them — only the address does.
    public var vpnCIDRs: [String] = []

    public static let empty = StarterLists(vpn: DomainSet(), direct: DomainSet())

    public static func forRegion(_ region: Region) -> StarterLists {
        switch region {
        case .none: return .empty
        case .russia: return .russia
        }
    }

    /// Derived from the service catalog: there is exactly one source of truth for "what is blocked / what must stay direct".
    public static let russia: StarterLists = {
        var vpn: [String] = [], direct = Catalog.russianTLDs, cidrs: [String] = []
        for s in Catalog.services {
            switch s.defaultRoute {
            case .vpn?: vpn += s.suffixes; cidrs += s.cidrs
            case .direct?: direct += s.suffixes
            default: break
            }
        }
        return StarterLists(vpn: DomainSet(suffixes: vpn), direct: DomainSet(suffixes: direct), vpnCIDRs: cidrs)
    }()

    public static let telegramCIDRs = Catalog.telegramCIDRs
}

// MARK: - Rule engine

/// Turns (host, port) into a routing decision. Precedence, most to least specific:
///   manual rules → learned verdicts → starter VPN list → starter direct list → recently-good direct → race.
public final class RuleEngine: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL?
    private let now: @Sendable () -> Date

    private var manualExact: [String: Route] = [:]
    private var manualSuffix: [String: Route] = [:]
    private var manualKeywords: [(String, Route)] = []
    private var manualCIDRs: [(IPv4CIDR, Route)] = []
    private var manualRules: [ManualRule] = []

    private var learned: [String: LearnedEntry] = [:]
    private var pendingFailures: [String: [Date]] = [:]
    private var recentDirectOK: [String: Date] = [:]
    private var settings = AppSettings()
    private var policy = CompiledPolicy()
    private var svcVPN = DomainSet(), svcDirect = DomainSet(), svcBlock = DomainSet()
    private var starterVPN = DomainSet(), starterDirect = DomainSet()
    private var svcVPNCIDRs: [IPv4CIDR] = [], svcDirectCIDRs: [IPv4CIDR] = [], starterVPNCIDRs: [IPv4CIDR] = []

    /// How many hard direct-path failures (within `failureWindow`) promote a domain to "vpn".
    public var promoteAfterFailures = 2
    public var failureWindow: TimeInterval = 120
    public var directOKTTL: TimeInterval = 30 * 60
    public var learnedExpiry: TimeInterval = 30 * 24 * 3600
    public var revalidateAfter: TimeInterval = 6 * 3600

    /// Called (off the lock) when a domain is promoted to "vpn" or removed automatically.
    public var onLearned: (@Sendable (LearnedEntry) -> Void)?
    public var onForgotten: (@Sendable (String) -> Void)?

    public init(directory: URL? = nil, region: Region = .russia, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        self.settings.region = region
        loadLearned()
        loadManual()
        recompile()
    }

    // MARK: Configuration

    public func setRegion(_ region: Region) {
        lock.lock(); settings.region = region; lock.unlock()
        recompile()
    }

    /// Feed the user's settings (service policies, scenarios, region, UDP) into the router.
    public func configure(settings s: AppSettings) {
        lock.lock(); settings = s; lock.unlock()
        recompile()
    }

    public var currentPolicy: CompiledPolicy { lock.lock(); defer { lock.unlock() }; return policy }

    private func recompile() {
        lock.lock()
        let p = PolicyCompiler.compile(settings: settings, manual: manualRules)
        policy = p
        svcVPN = DomainSet(suffixes: p.allSvcVPN); svcDirect = DomainSet(suffixes: p.svcDirect); svcBlock = DomainSet(suffixes: p.svcBlock)
        starterVPN = DomainSet(suffixes: p.allStarterVPN); starterDirect = DomainSet(suffixes: p.starterDirect)
        svcVPNCIDRs = p.svcVPNCIDR.values.flatMap { $0 }.compactMap(IPv4CIDR.init)
        svcDirectCIDRs = p.svcDirectCIDR.compactMap(IPv4CIDR.init)
        starterVPNCIDRs = p.starterVPNCIDR.values.flatMap { $0 }.compactMap(IPv4CIDR.init)
        lock.unlock()
    }

    public func setManualRules(_ rules: [ManualRule], persist: Bool = true) {
        lock.lock()
        manualRules = rules
        manualExact = [:]; manualSuffix = [:]; manualKeywords = []; manualCIDRs = []
        for r in rules {
            switch r.kind {
            case .exact: manualExact[r.value] = r.route
            case .suffix: manualSuffix[r.value] = r.route
            case .keyword: manualKeywords.append((r.value, r.route))
            case .cidr: if let c = IPv4CIDR(r.value) { manualCIDRs.append((c, r.route)) }
            case .app: break                       // per-app rules only exist in tunnel mode (needs the process behind a flow)
            }
        }
        lock.unlock()
        recompile()
        if persist { saveManual() }
    }

    public var manual: [ManualRule] { lock.lock(); defer { lock.unlock() }; return manualRules }

    /// Adds (or replaces) a manual rule for a whole domain.
    public func pin(host: String, route: Route?) {
        let key = registrableDomain(host)
        var rules = manual.filter { !($0.kind == .suffix && $0.value == key) && !($0.kind == .exact && $0.value == key) }
        if let route { rules.append(ManualRule(route: route, kind: isIPLiteral(host) ? .exact : .suffix, value: key)) }
        setManualRules(rules)
        if route != nil { forget(domain: key) }
    }

    // MARK: Decision

    public func decide(host rawHost: String, port: UInt16) -> Decision {
        let host = normalizeHost(rawHost)
        if isLocalHost(host) { return Decision(.direct, .local) }

        lock.lock()
        defer { lock.unlock() }

        if let route = manualMatch(host) {
            switch route {
            case .direct: return Decision(.direct, .manual)
            case .vpn: return Decision(.vpn, .manual)
            case .block: return Decision(.block, .manual)
            }
        }

        // Explicit choices (your service policies and active scenarios) beat everything learned.
        let v4 = ipv4Value(host)
        if svcBlock.matches(host) { return Decision(.block, .manual) }
        if svcDirect.matches(host) || (v4.map { v in svcDirectCIDRs.contains { $0.contains(v) } } ?? false) { return Decision(.direct, .manual) }
        if svcVPN.matches(host) || (v4.map { v in svcVPNCIDRs.contains { $0.contains(v) } } ?? false) { return Decision(.vpn, .manual, allowFallback: true) }

        let key = registrableDomain(host)
        if let e = learned[key], now().timeIntervalSince(e.lastConfirmed) < learnedExpiry {
            return Decision(.vpn, .learned, allowFallback: true)
        }
        if starterVPN.matches(host) { return Decision(.vpn, .starter, allowFallback: true) }
        if let v = v4, starterVPNCIDRs.contains(where: { $0.contains(v) }) { return Decision(.vpn, .starter, allowFallback: true) }
        if starterDirect.matches(host) { return Decision(.direct, .starter) }
        if let t = recentDirectOK[key], now().timeIntervalSince(t) < directOKTTL {
            return Decision(.direct, .learned, allowFallback: true)
        }
        return Decision(Self.isRaceable(port: port) ? .race : .direct, .unknown, allowFallback: true)
    }

    /// Web ports where the client speaks first, so the first request can be replayed on another path.
    public static func isRaceable(port: UInt16) -> Bool { [80, 443, 8080, 8443].contains(port) }

    private func manualMatch(_ host: String) -> Route? {
        if let r = manualExact[host] { return r }
        if let v = ipv4Value(host) {
            var best: (Int, Route)?
            for (cidr, route) in manualCIDRs where cidr.contains(v) {
                let specificity = cidr.mask.nonzeroBitCount
                if best == nil || specificity > best!.0 { best = (specificity, route) }
            }
            return best?.1
        }
        var s = Substring(host)
        while true {
            if let r = manualSuffix[String(s)] { return r }
            guard let dot = s.firstIndex(of: ".") else { break }
            s = s[s.index(after: dot)...]
        }
        for (kw, route) in manualKeywords where host.contains(kw) { return route }
        return nil
    }

    // MARK: Evidence from the race

    public func noteDirectOK(host: String) {
        let key = registrableDomain(host)
        lock.lock()
        if recentDirectOK.count > 4096 { recentDirectOK.removeAll(keepingCapacity: true) }
        recentDirectOK[key] = now()
        pendingFailures[key] = nil
        lock.unlock()
    }

    /// The direct path failed hard (RST, timeout, DNS failure, garbage) while the VPN path worked.
    /// Returns true if this promoted the domain to "vpn".
    @discardableResult
    public func noteDirectBlocked(host: String) -> Bool {
        let key = registrableDomain(host)
        var promoted: LearnedEntry?
        lock.lock()
        let t = now()
        recentDirectOK[key] = nil
        var recent = (pendingFailures[key] ?? []).filter { t.timeIntervalSince($0) < failureWindow }
        recent.append(t)
        if learned[key] != nil {
            learned[key]!.lastConfirmed = t
            learned[key]!.hits += 1
            pendingFailures[key] = nil
        } else if recent.count >= promoteAfterFailures {
            let e = LearnedEntry(domain: key, learnedAt: t, lastConfirmed: t, hits: recent.count)
            learned[key] = e
            pendingFailures[key] = nil
            promoted = e
        } else {
            pendingFailures[key] = recent
        }
        lock.unlock()
        if let promoted {
            saveLearned()
            onLearned?(promoted)
            return true
        }
        return false
    }

    // MARK: Learned store

    public var learnedEntries: [LearnedEntry] {
        lock.lock(); defer { lock.unlock() }
        return learned.values.sorted { $0.learnedAt > $1.learnedAt }
    }

    public func forget(domain: String) {
        lock.lock()
        let had = learned.removeValue(forKey: domain) != nil
        pendingFailures[domain] = nil
        lock.unlock()
        if had { saveLearned(); onForgotten?(domain) }
    }

    public func clearLearned() {
        lock.lock(); let keys = Array(learned.keys); learned.removeAll(); pendingFailures.removeAll(); lock.unlock()
        saveLearned()
        keys.forEach { onForgotten?($0) }
    }

    /// Learned domains that were not re-checked recently — candidates for a background direct probe.
    public func needsRevalidation(host: String) -> Bool {
        let key = registrableDomain(host)
        lock.lock(); defer { lock.unlock() }
        guard let e = learned[key] else { return false }
        return now().timeIntervalSince(e.lastConfirmed) > revalidateAfter
    }

    public func markConfirmed(host: String) {
        let key = registrableDomain(host)
        lock.lock(); learned[key]?.lastConfirmed = now(); lock.unlock()
        saveLearned()
    }

    // MARK: Persistence

    private var learnedURL: URL? { directory?.appendingPathComponent("learned.json") }
    private var manualURL: URL? { directory?.appendingPathComponent("rules.txt") }

    private func loadLearned() {
        guard let url = learnedURL, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let list = try? dec.decode([LearnedEntry].self, from: data) {
            learned = Dictionary(uniqueKeysWithValues: list.map { ($0.domain, $0) })
        }
    }

    private func saveLearned() {
        guard let url = learnedURL else { return }
        lock.lock(); let list = Array(learned.values); lock.unlock()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? enc.encode(list.sorted { $0.domain < $1.domain }) { try? data.write(to: url, options: .atomic) }
    }

    private func loadManual() {
        guard let url = manualURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        setManualRules(ManualRule.parseAll(text), persist: false)
    }

    private func saveManual() {
        guard let url = manualURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "# Waypoint: ручные правила. Формат: <vpn|direct|block> <домен | full:хост | keyword:слово | cidr:1.2.3.0/24>\n"
        try? (header + ManualRule.serialize(manual)).write(to: url, atomically: true, encoding: .utf8)
    }
}
