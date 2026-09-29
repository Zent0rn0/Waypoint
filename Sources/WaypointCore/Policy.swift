import Foundation

// MARK: - Per-app rules

/// `app:` rules name an application bundle (or a plain executable) by absolute path. Matching in sing-box is by process
/// path regex, so a bundle path also covers every helper process inside it (Electron/Chromium apps network from helpers).
public enum AppPath {
    /// Never routable by the user: routing these into the tunnel would loop (Waypoint, Happ's tunnel provider) or cut the plumbing.
    static let reserved = ["/waypoint.app/", "/happ.app/", "sing-box", "/libexec/waypoint/"]

    public static func isValid(_ p: String) -> Bool {
        guard p.hasPrefix("/"), p.count > 3, p.count <= 300 else { return false }
        if p.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == "\"" || $0 == "\\" }) { return false }
        if p.split(separator: "/").contains("..") { return false }
        let l = p.lowercased() + "/"
        return !reserved.contains { l.contains($0) }
    }

    /// The bundle root if the path is inside a `.app`, otherwise the path itself.
    public static func canonical(_ p: String) -> String {
        if let r = p.range(of: ".app/") { return String(p[..<r.lowerBound]) + ".app" }
        return p
    }

    public static func displayName(_ p: String) -> String {
        let last = canonical(p).split(separator: "/").last.map(String.init) ?? p
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// RE2 (Go) regex: bundle → prefix match, executable → exact match.
    public static func regex(_ p: String) -> String {
        let c = canonical(p)
        return c.hasSuffix(".app") ? "^\(quote(c))/" : "^\(quote(c))$"
    }

    static func quote(_ s: String) -> String {
        var out = ""
        for ch in s { if "\\.+*?()|[]{}^$".contains(ch) { out.append("\\") }; out.append(ch) }
        return out
    }
}

// MARK: - Compiled policy

/// Everything the user (and the active scenarios) decided, flattened into lists. Consumed by the in-app router
/// (`RuleEngine`) and by the tunnel config generator, so both always agree.
public struct CompiledPolicy: Sendable, Equatable {
    public var svcVPN: [PoolClass: [String]] = [:]
    public var svcVPNCIDR: [PoolClass: [String]] = [:]
    public var svcDirect: [String] = []
    public var svcDirectCIDR: [String] = []
    public var svcBlock: [String] = []
    public var starterVPN: [PoolClass: [String]] = [:]
    public var starterVPNCIDR: [PoolClass: [String]] = [:]
    public var starterDirect: [String] = []
    public var appRules: [ManualRule] = []
    public var udpViaVPN = false
    public var finalMode: FinalMode = .auto
    public var region: Region = .russia

    public init() {}
    public var allSvcVPN: [String] { svcVPN.values.flatMap { $0 } }
    public var allStarterVPN: [String] { starterVPN.values.flatMap { $0 } }
}

public enum PolicyCompiler {
    /// Precedence for one service: the user's explicit choice > active scenarios (direct beats vpn) > catalog default
    /// (Russian region only) > nothing ("auto": direct, and the racer learns from failures).
    public static func compile(settings s: AppSettings, manual: [ManualRule]) -> CompiledPolicy {
        var p = CompiledPolicy()
        let active = (s.playbooks ?? []).compactMap(Playbook.playbook)
        p.region = active.compactMap(\.regionOverride).first ?? s.region
        let policies = s.servicePolicies ?? [:]

        for svc in Catalog.services {
            var route: Route?
            if let raw = policies[svc.id], let r = Route(rawValue: raw) {
                route = r
            } else {
                if active.contains(where: { $0.direct.contains(svc.id) }) { route = .direct }
                else if active.contains(where: { $0.vpn.contains(svc.id) }) { route = .vpn }
            }
            if let route {
                switch route {
                case .vpn: p.svcVPN[svc.pool, default: []] += svc.suffixes; p.svcVPNCIDR[svc.pool, default: []] += svc.cidrs
                case .direct: p.svcDirect += svc.suffixes; p.svcDirectCIDR += svc.cidrs
                case .block: p.svcBlock += svc.suffixes
                }
            } else if p.region == .russia, let d = svc.defaultRoute {
                switch d {
                case .vpn: p.starterVPN[svc.pool, default: []] += svc.suffixes; p.starterVPNCIDR[svc.pool, default: []] += svc.cidrs
                case .direct: p.starterDirect += svc.suffixes
                case .block: break
                }
            }
        }
        if p.region == .russia { p.starterDirect += Catalog.russianTLDs }

        p.appRules = manual.filter { $0.kind == .app }
        p.udpViaVPN = (s.tunnelUDPViaVPN ?? false) || active.contains { $0.udpViaVPN }
        if active.contains(where: { $0.finalMode == .allVPN }) { p.finalMode = .allVPN }
        else if active.contains(where: { $0.finalMode == .savings }) { p.finalMode = .savings }
        return p
    }
}
