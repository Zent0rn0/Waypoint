import Foundation

// MARK: - Per-connection rules

/// Where one kind of connection goes. Beyond the three routes of `rules.txt` it can name the VPN client alone
/// or one exact server, so every app / site / app+site pair can be steered anywhere.
public enum ConnectionTarget: Hashable, Sendable, Codable {
    case direct, vpn, client, block
    case server(String)                  // ServerEntry.id

    public var raw: String {
        switch self {
        case .direct: "direct"; case .vpn: "vpn"; case .client: "client"; case .block: "block"
        case .server(let id): "server:\(id)"
        }
    }
    public init?(raw: String) {
        switch raw {
        case "direct": self = .direct; case "vpn": self = .vpn; case "client": self = .client; case "block": self = .block
        default:
            guard raw.hasPrefix("server:"), case let id = String(raw.dropFirst(7)), !id.isEmpty else { return nil }
            self = .server(id)
        }
    }
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let t = ConnectionTarget(raw: s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad target \(s)")) }
        self = t
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }

    /// The plain route when the target is one of the three `rules.txt` routes.
    public var route: Route? {
        switch self { case .direct: .direct; case .vpn: .vpn; case .block: .block; default: nil }
    }
    public init(_ route: Route) {
        switch route { case .direct: self = .direct; case .vpn: self = .vpn; case .block: self = .block }
    }
}

/// «Discord → discord.com → напрямую», «Telegram → только через сервер Германия», «youtube.com → через VPN-клиент».
/// At least one of `app` / `site` is set; both set = the rule applies only to that app talking to that site.
public struct ConnectionRule: Codable, Hashable, Identifiable, Sendable {
    public var app: String?              // canonical bundle or executable path
    public var site: String?             // domain (with subdomains) or IPv4 CIDR
    public var target: ConnectionTarget

    public init?(app: String?, site: String?, target: ConnectionTarget) {
        let a = app.map(AppPath.canonical)
        let s = site.flatMap(ConnectionRule.normalizeSite)
        if app != nil && (a.map(AppPath.isValid) != true) { return nil }
        if site != nil && s == nil { return nil }
        guard a != nil || s != nil else { return nil }
        self.app = a; self.site = s; self.target = target
    }

    public var id: String { (app ?? "*") + " → " + (site ?? "*") }
    public enum Tier: String, CaseIterable, Sendable { case pair, app, site }
    public var tier: Tier { app != nil && site != nil ? .pair : (app != nil ? .app : .site) }

    /// «https://www.YouTube.com/watch» → «youtube.com»-style host; CIDR kept as is; anything else rejected.
    public static func normalizeSite(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ipv4Value(t) != nil { return t + "/32" }
        if t.contains("/"), IPv4CIDR(t) != nil { return t }
        if t.contains("://") { t = URL(string: t)?.host ?? t }
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        if t.hasPrefix("www.") { t = String(t.dropFirst(4)) }
        while t.hasPrefix(".") { t.removeFirst() }
        return TunnelConfig.isValidHostname(t) ? t : nil
    }

    public func matches(app path: String?, host: String) -> Bool {
        if let a = app { guard let path, AppPath.canonical(path) == a || path.hasPrefix(a + "/") else { return false } }
        if let s = site {
            if let c = IPv4CIDR(s) { guard let v = ipv4Value(host), c.contains(v) else { return false } }
            else { let h = host.lowercased(); guard h == s || h.hasSuffix("." + s) else { return false } }
        }
        return true
    }
}

public enum ConnectionRuleStore {
    public static let fileName = "connection-rules.json"

    /// Invalid entries (hand-edited file, removed app) are dropped, never fatal.
    public static func load(from dir: URL) -> [ConnectionRule] {
        struct Raw: Decodable { var app: String?; var site: String?; var target: String? }
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(fileName)),
              let raw = try? JSONDecoder().decode([Raw].self, from: d) else { return [] }
        var seen = Set<String>()
        return raw.compactMap { r in r.target.flatMap(ConnectionTarget.init(raw:)).flatMap { ConnectionRule(app: r.app, site: r.site, target: $0) } }
            .filter { seen.insert($0.id).inserted }
    }
    public static func save(_ list: [ConnectionRule], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(list) { try? d.write(to: dir.appendingPathComponent(fileName), options: .atomic) }
    }
}

// MARK: - Tunnel side

/// Connection rules become rule-sets named `conn-<tier>-<target>`: one rule per connection rule (app regex AND site),
/// so editing them is a hot reload. Only a *new server* as a target changes the config structure (and restarts sing-box).
public struct ConnectionPlan: Equatable, Sendable {
    public var files: [String: Data] = [:]
    /// Server outbound tags that rules point at, in config order.
    public var serverTags: [String] = []

    public static let fixedTargets = ["direct", "vpn", "client", "block"]
    public static func setName(_ tier: ConnectionRule.Tier, _ target: String) -> String { "conn-\(tier.rawValue)-\(target)" }
    public static var fixedTags: [String] {
        ConnectionRule.Tier.allCases.flatMap { t in fixedTargets.map { setName(t, $0) } }
    }

    /// `servers`: the enabled outbounds (tag + entry id). A rule naming a server that is off or gone falls back to the best VPN.
    public static func build(_ rules: [ConnectionRule], servers: [(tag: String, id: String)]) -> ConnectionPlan {
        var buckets: [String: [[String: Any]]] = [:]
        for t in ConnectionRule.Tier.allCases { for f in fixedTargets { buckets[setName(t, f)] = [] } }
        var tags: [String] = []
        for r in rules {
            var rule: [String: Any] = [:]
            if let a = r.app { guard AppPath.isValid(a) else { continue }; rule["process_path_regex"] = [AppPath.regex(a)] }
            if let s = r.site {
                if IPv4CIDR(s) != nil { rule["ip_cidr"] = [s] }
                else if TunnelConfig.isValidHostname(s) { rule["domain_suffix"] = [s] }
                else { continue }
            }
            guard !rule.isEmpty else { continue }
            var target: String
            switch r.target {
            case .server(let id):
                if let tag = servers.first(where: { $0.id == id })?.tag { target = tag; if !tags.contains(tag) { tags.append(tag) } }
                else { target = "vpn" }
            default: target = r.target.raw
            }
            buckets[setName(r.tier, target), default: []].append(rule)
        }
        var plan = ConnectionPlan()
        plan.serverTags = servers.map(\.tag).filter(tags.contains)
        for tag in plan.serverTags { for t in ConnectionRule.Tier.allCases where buckets[setName(t, tag)] == nil { buckets[setName(t, tag)] = [] } }   // the config names every tier
        for (name, list) in buckets {
            let rules = list.isEmpty ? [["domain": ["waypoint-placeholder.invalid"]]] : list   // an empty rule would match everything
            plan.files[name] = (try? JSONSerialization.data(withJSONObject: ["version": 5, "rules": rules], options: [.sortedKeys, .prettyPrinted])) ?? Data()
        }
        return plan
    }
}
