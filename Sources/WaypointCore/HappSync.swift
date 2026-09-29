import Foundation

/// Exports Waypoint's knowledge as a Happ routing profile, so apps that ignore the system proxy
/// (Telegram, games, …) are routed by Happ's own TUN rules the same way.
/// Format: https://www.happ.su/main/dev-docs/routing — JSON, base64, opened as happ://routing/add|onadd/<base64>.
public enum HappRouting {
    public static let geoipURL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    public static let geositeURL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

    public struct Lists: Equatable {
        public var proxySites: [String], proxyIP: [String], directSites: [String], directIP: [String], blockSites: [String]
    }

    /// Learned + manual + the compiled policy (service choices, scenarios, catalog defaults) → Xray-style entries
    /// (`domain:` = the domain and its subdomains). Per-app rules cannot be expressed in Happ and are skipped.
    public static func lists(rules: RuleEngine, region: Region) -> Lists {
        var l = Lists(proxySites: [], proxyIP: [], directSites: [], directIP: [], blockSites: [])
        func site(_ entry: String, _ route: Route) {
            switch route {
            case .vpn: l.proxySites.append(entry)
            case .direct: l.directSites.append(entry)
            case .block: l.blockSites.append(entry)
            }
        }
        func ip(_ entry: String, _ route: Route) {
            switch route {
            case .vpn: l.proxyIP.append(entry)
            case .direct: l.directIP.append(entry)
            case .block: break
            }
        }
        for e in rules.learnedEntries {
            let bare = e.domain.split(separator: "/").first.map(String.init) ?? e.domain
            if isIPLiteral(bare) { ip(e.domain, .vpn) } else { site("domain:\(e.domain)", .vpn) }
        }
        for r in rules.manual {
            switch r.kind {
            case .suffix: site("domain:\(r.value)", r.route)
            case .exact: if isIPLiteral(r.value) { ip(r.value, r.route) } else { site("full:\(r.value)", r.route) }
            case .keyword: site("keyword:\(r.value)", r.route)
            case .cidr: ip(r.value, r.route)
            case .app: break
            }
        }
        let p = rules.currentPolicy
        l.proxySites += p.allSvcVPN.map { "domain:\($0)" } + p.allStarterVPN.map { "domain:\($0)" }
        l.proxyIP += p.svcVPNCIDR.values.flatMap { $0 } + p.starterVPNCIDR.values.flatMap { $0 }
        l.directSites += (p.svcDirect + p.starterDirect).map { "domain:\($0)" }
        l.directIP += p.svcDirectCIDR
        l.blockSites += p.svcBlock.map { "domain:\($0)" }
        func dedupe(_ a: [String]) -> [String] { var seen = Set<String>(); return a.filter { seen.insert($0).inserted } }
        return Lists(proxySites: dedupe(l.proxySites), proxyIP: dedupe(l.proxyIP), directSites: dedupe(l.directSites),
                     directIP: dedupe(l.directIP), blockSites: dedupe(l.blockSites))
    }

    /// `GlobalProxy = "false"`: only ProxySites go through the VPN, the rest is direct — the model Waypoint itself uses.
    public static func profileJSON(_ l: Lists, name: String = "Waypoint") -> Data {
        let obj: [String: Any] = [
            "Name": name, "GlobalProxy": "false",
            "RemoteDNSType": "DoH", "RemoteDNSDomain": "https://cloudflare-dns.com/dns-query", "RemoteDNSIP": "1.1.1.1",
            "DomesticDNSType": "DoU", "DomesticDNSDomain": "", "DomesticDNSIP": "77.88.8.8",
            "Geoipurl": geoipURL, "Geositeurl": geositeURL, "LastUpdated": String(Int(Date().timeIntervalSince1970)),
            "DnsHosts": [String: String](),
            "DirectSites": l.directSites, "DirectIp": l.directIP + ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
            "ProxySites": l.proxySites, "ProxyIp": l.proxyIP, "BlockSites": l.blockSites, "BlockIp": [String](),
            "DomainStrategy": "IPIfNonMatch", "FakeDNS": "false",
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    /// `activate == false` → `add` (Happ imports the profile; you pick it there). `true` → `onadd` (replaces the active profile).
    public static func deeplink(_ json: Data, activate: Bool) -> URL? {
        URL(string: "happ://routing/\(activate ? "onadd" : "add")/\(json.base64EncodedString())")
    }
}

extension DomainSet {
    var suffixList: [String] { suffixes.sorted() }
}
