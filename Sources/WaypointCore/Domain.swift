import Foundation

// MARK: - Host normalisation & classification

public func normalizeHost(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

public func ipv4Value(_ s: String) -> UInt32? {
    var addr = in_addr()
    guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
    return UInt32(bigEndian: addr.s_addr)
}

public func isIPv6Literal(_ s: String) -> Bool {
    var addr = in6_addr()
    return inet_pton(AF_INET6, s, &addr) == 1
}

public func isIPLiteral(_ s: String) -> Bool { ipv4Value(s) != nil || isIPv6Literal(s) }

/// Loopback, LAN, link-local, CGNAT/Tailscale, mDNS names and single-label names: never worth routing cleverly.
public func isLocalHost(_ host: String) -> Bool {
    let h = normalizeHost(host)
    if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".localhost") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") { return true }
    if let v = ipv4Value(h) {
        let a = v >> 24, b = (v >> 16) & 0xff
        if a == 127 || a == 10 || a == 0 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 169 && b == 254 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        return false
    }
    if isIPv6Literal(h) {
        return h == "::1" || h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd")
    }
    return !h.contains(".")
}

public func isLoopback(_ host: String) -> Bool {
    let h = normalizeHost(host)
    if h == "localhost" || h == "::1" { return true }
    if let v = ipv4Value(h) { return (v >> 24) == 127 }
    return false
}

// MARK: - Registrable domain (learning granularity)

// Not a full Public Suffix List: a small table of the second-level suffixes and multi-tenant
// hosting domains that matter in practice. Learning at "example.co.uk" instead of "co.uk"
// is what keeps one blocked site from dragging a whole country TLD through the VPN.
private let twoLevelSuffixes: Set<String> = [
    "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "co.kr",
    "com.br", "com.cn", "com.tr", "com.ua", "co.in", "co.nz", "co.za", "com.mx", "com.ar",
    "com.sg", "com.hk", "com.tw", "com.pl", "com.es",
    // multi-tenant platforms: each customer is a different "site"
    "github.io", "blogspot.com", "cloudfront.net", "amazonaws.com", "herokuapp.com", "vercel.app",
    "netlify.app", "pages.dev", "workers.dev", "azurewebsites.net", "web.app", "firebaseapp.com",
    "fly.dev", "onrender.com", "appspot.com",
]

/// Key under which a host's routing verdict is learned.
/// Domains → registrable domain; IPv4 → its /24 (blocklists work on ranges); IPv6 → the literal.
public func registrableDomain(_ rawHost: String) -> String {
    let host = normalizeHost(rawHost)
    if let v = ipv4Value(host) {
        return "\(v >> 24).\((v >> 16) & 0xff).\((v >> 8) & 0xff).0/24"
    }
    if isIPv6Literal(host) { return host }
    let labels = host.split(separator: ".").map(String.init)
    if labels.count <= 2 { return host }
    let last2 = labels.suffix(2).joined(separator: ".")
    let take = twoLevelSuffixes.contains(last2) ? 3 : 2
    return labels.suffix(take).joined(separator: ".")
}

// MARK: - Domain sets

/// Suffix / exact / keyword matching. `youtube.com` matches `youtube.com` and `*.youtube.com`.
public struct DomainSet: Sendable {
    fileprivate(set) var suffixes = Set<String>()
    private var exact = Set<String>()
    private var keywords = [String]()

    public init(suffixes: [String] = [], exact: [String] = [], keywords: [String] = []) {
        self.suffixes = Set(suffixes.map(normalizeHost))
        self.exact = Set(exact.map(normalizeHost))
        self.keywords = keywords.map { $0.lowercased() }
    }

    public var isEmpty: Bool { suffixes.isEmpty && exact.isEmpty && keywords.isEmpty }

    public func matches(_ rawHost: String) -> Bool {
        let host = normalizeHost(rawHost)
        if exact.contains(host) { return true }
        if matchesSuffix(host) { return true }
        return keywords.contains { host.contains($0) }
    }

    func matchesSuffix(_ host: String) -> Bool {
        var s = Substring(host)
        while true {
            if suffixes.contains(String(s)) { return true }
            guard let dot = s.firstIndex(of: ".") else { return false }
            s = s[s.index(after: dot)...]
        }
    }
}

// MARK: - CIDR

public struct IPv4CIDR: Equatable, Sendable {
    public let network: UInt32
    public let mask: UInt32
    public init?(_ text: String) {
        let parts = text.split(separator: "/")
        guard let ip = ipv4Value(String(parts[0])) else { return nil }
        let bits = parts.count > 1 ? Int(parts[1]) ?? -1 : 32
        guard (0...32).contains(bits) else { return nil }
        let m: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
        network = ip & m
        mask = m
    }
    public func contains(_ ip: UInt32) -> Bool { (ip & mask) == network }
}
