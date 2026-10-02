import Foundation

// Some servers only work with Xray (Happ's engine): newer REALITY deployments that sing-box's client fails to verify,
// and the xhttp transport. For those, Waypoint runs Xray as a helper: one local SOCKS port per server, dialing out
// through the physical interface. The tunnel's sing-box treats each such server as a loopback SOCKS outbound.

public enum XrayLink {
    static let flows: Set<String> = ["xtls-rprx-vision", "xtls-rprx-vision-udp443"]
    static let fingerprints: Set<String> = ["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"]
    static let xhttpModes: Set<String> = ["auto", "packet-up", "stream-up", "stream-one"]

    /// Builds a validated Xray outbound (without tag / sockopt) from a share link.
    public static func parse(_ raw: String) throws -> ParsedServer {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = text.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
        switch scheme {
        case "vless", "trojan": return try urlBased(text, proto: scheme)
        default:
            // vmess / ss / hysteria2 / https are handled by sing-box
            throw ShareLinkError.unsupported("Xray-путь для «\(scheme)» не нужен")
        }
    }

    private static func urlBased(_ text: String, proto: String) throws -> ParsedServer {
        guard let c = URLComponents(string: text), let host = c.host, ShareLink.validHost(host) else { throw ShareLinkError.malformed("адрес сервера") }
        let port = c.port ?? 443
        guard (1...65535).contains(port) else { throw ShareLinkError.malformed("порт") }
        let user = c.percentEncodedUser?.removingPercentEncoding ?? ""
        guard !user.isEmpty, ShareLink.safeText(user, max: 128) else { throw ShareLinkError.malformed("ключ") }
        var q: [String: String] = [:]
        for i in c.queryItems ?? [] { if let v = i.value, !v.isEmpty { q[i.name.lowercased()] = v } }
        let name = (c.fragment?.removingPercentEncoding).flatMap { ShareLink.safeText($0, max: 80) && !$0.isEmpty ? $0 : nil } ?? host

        func param(_ k: String, max: Int = 200) throws -> String? {
            guard let v = q[k] else { return nil }
            guard ShareLink.safeText(v, max: max) else { throw ShareLinkError.malformed(k) }
            return v
        }
        func hostParam(_ k: String) throws -> String? {
            guard let v = q[k] else { return nil }
            guard ShareLink.validHost(v) else { throw ShareLinkError.malformed(k) }
            return v
        }

        var network = (q["type"] ?? "tcp").lowercased()
        if network == "raw" { network = "tcp" }
        var stream: [String: Any] = ["network": network]
        switch network {
        case "tcp":
            if let ht = q["headertype"], ht != "none" { throw ShareLinkError.unsupported("tcp headerType=\(ht)") }
        case "ws":
            var s: [String: Any] = [:]
            if let p = try param("path") { s["path"] = p }
            if let h = try hostParam("host") { s["host"] = h }
            stream["wsSettings"] = s
        case "grpc":
            var s: [String: Any] = [:]
            if let n = try param("servicename", max: 80) { s["serviceName"] = n }
            if q["mode"] == "multi" { s["multiMode"] = true }
            stream["grpcSettings"] = s
        case "httpupgrade":
            var s: [String: Any] = [:]
            if let p = try param("path") { s["path"] = p }
            if let h = try hostParam("host") { s["host"] = h }
            stream["httpupgradeSettings"] = s
        case "xhttp", "splithttp":
            stream["network"] = "xhttp"
            var s: [String: Any] = [:]
            if let p = try param("path") { s["path"] = p }
            if let h = try hostParam("host") { s["host"] = h }
            if let m = q["mode"] { guard xhttpModes.contains(m) else { throw ShareLinkError.unsupported("xhttp mode=\(m)") }; s["mode"] = m }
            stream["xhttpSettings"] = s
        default:
            throw ShareLinkError.unsupported("транспорт \(network)")
        }

        let security = (q["security"] ?? (proto == "trojan" ? "tls" : "none")).lowercased()
        let fp = q["fp"].flatMap { fingerprints.contains($0) ? $0 : nil }
        let sni = try hostParam("sni") ?? (try hostParam("peer"))
        switch security {
        case "none": stream["security"] = "none"
        case "tls":
            var t: [String: Any] = ["serverName": sni ?? host]
            if let fp { t["fingerprint"] = fp }
            if let a = try param("alpn", max: 40) { t["alpn"] = a.split(separator: ",").map(String.init) }
            if q["allowinsecure"] == "1" || q["insecure"] == "1" { t["allowInsecure"] = true }
            stream["security"] = "tls"; stream["tlsSettings"] = t
        case "reality":
            guard let pbk = q["pbk"], pbk.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else { throw ShareLinkError.malformed("reality public key") }
            let sid = q["sid"] ?? ""
            guard sid.range(of: #"^[0-9A-Fa-f]{0,16}$"#, options: .regularExpression) != nil else { throw ShareLinkError.malformed("reality short id") }
            var r: [String: Any] = ["serverName": sni ?? host, "publicKey": pbk, "shortId": sid, "fingerprint": fp ?? "chrome"]
            if let spx = try param("spx", max: 120) { r["spiderX"] = spx }
            stream["security"] = "reality"; stream["realitySettings"] = r
        default:
            throw ShareLinkError.unsupported("security=\(security)")
        }

        var o: [String: Any] = ["protocol": proto, "streamSettings": stream]
        if proto == "vless" {
            guard UUID(uuidString: user) != nil else { throw ShareLinkError.malformed("UUID") }
            var u: [String: Any] = ["id": user, "encryption": "none"]
            if let f = q["flow"] { guard flows.contains(f) else { throw ShareLinkError.unsupported("flow \(f)") }; u["flow"] = f }
            o["settings"] = ["vnext": [["address": host, "port": port, "users": [u]]]]
        } else {
            o["settings"] = ["servers": [["address": host, "port": port, "password": user]]]
        }
        var p = ParsedServer(name: name, host: host, port: port, proto: proto, outbound: o)
        p.xrayOnly = true
        return p
    }

    /// Complete Xray config: one SOCKS inbound per (port, link), each routed to its server; sockets pinned to `interface`.
    public static func config(_ items: [(port: Int, link: String)], interface: String, logLevel: String = "warning") -> Data? {
        guard TunnelConfig.isValidInterface(interface) else { return nil }
        var inbounds: [[String: Any]] = [], outbounds: [[String: Any]] = [], rules: [[String: Any]] = []
        for it in items {
            guard (1025...65535).contains(it.port), let p = try? parse(it.link) else { continue }
            var o = p.outbound
            o["tag"] = "out-\(it.port)"
            var stream = o["streamSettings"] as? [String: Any] ?? [:]
            stream["sockopt"] = ["interface": interface]
            o["streamSettings"] = stream
            outbounds.append(o)
            inbounds.append(["tag": "in-\(it.port)", "listen": "127.0.0.1", "port": it.port, "protocol": "socks", "settings": ["udp": true]])
            rules.append(["type": "field", "inboundTag": ["in-\(it.port)"], "outboundTag": "out-\(it.port)"])
        }
        guard !inbounds.isEmpty else { return nil }
        outbounds.append(["tag": "block", "protocol": "blackhole"])
        let cfg: [String: Any] = ["log": ["loglevel": logLevel], "inbounds": inbounds, "outbounds": outbounds,
                                  "routing": ["domainStrategy": "AsIs", "rules": rules]]
        return try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])
    }
}

/// Keeps one Xray helper process running with exactly the enabled Xray-engine servers (user privileges, no root).
public final class XrayRunner: @unchecked Sendable {
    private let binary: URL
    private let dir: URL
    private let lock = NSLock()
    private var proc: Process?
    private var current: Data?
    private var lastStart = Date.distantPast

    public init(binary: URL, dir: URL) {
        self.binary = binary; self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private var pidURL: URL { dir.appendingPathComponent("xray.pid") }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return proc?.isRunning ?? false }

    /// A previous app instance that crashed may have left its helper behind.
    public func killStale() {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8), let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        let r = runProcess("/bin/ps", ["-p", String(pid), "-o", "comm="])
        if r.out.contains("xray") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: pidURL)
    }

    public func apply(servers: [ServerEntry], interface: String) {
        let items = servers.filter { $0.enabled && $0.engine == "xray" }.compactMap { e in e.localPort.map { (port: $0, link: e.link) } }
        let cfg = XrayLink.config(items, interface: interface)
        lock.lock()
        let same = cfg == current && (proc?.isRunning ?? false)
        // Died on its own (crash, killed): restart it, but never in a tight loop if it keeps dying right away.
        let crashedJustNow = cfg == current && proc != nil && !(proc?.isRunning ?? false) && Date().timeIntervalSince(lastStart) < 10
        lock.unlock()
        if same || crashedJustNow { return }
        stop()
        guard let cfg, FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let url = dir.appendingPathComponent("xray.json")
        guard (try? cfg.write(to: url, options: .atomic)) != nil else { return }
        let p = Process()
        p.executableURL = binary
        p.arguments = ["run", "-c", url.path]
        let log = dir.appendingPathComponent("xray.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let h = FileHandle(forWritingAtPath: log.path)
        p.standardOutput = h; p.standardError = h
        do { try p.run() } catch { return }
        try? String(p.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
        lock.lock(); proc = p; current = cfg; lastStart = Date(); lock.unlock()
    }

    public func stop() {
        lock.lock(); let p = proc; proc = nil; current = nil; lock.unlock()
        if let p, p.isRunning { p.terminate(); p.waitUntilExit() }
        try? FileManager.default.removeItem(at: pidURL)
    }
}
