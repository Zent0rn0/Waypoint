import Foundation

// MARK: - Additional servers (user-supplied share links) for the smart pool

/// The user's own servers, in addition to the VPN client. Waypoint never reads another app's stored servers or decrypts
/// its subscriptions: whatever is here was pasted in by the user. The VPN client itself always stays a member of every pool.
public struct ServerEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var link: String
    public var enabled: Bool
    /// Id of the subscription this server came from; nil = added by hand.
    public var source: String?
    /// "xray" when this server is carried by the Xray helper (on `localPort`); nil = sing-box directly.
    public var engine: String?
    public var localPort: Int?
    /// Result of the last check: works, latency, the country websites see.
    public var works: Bool?
    public var ms: Int?
    public var exit: String?
    public var checked: Date?
    public init(id: String = UUID().uuidString, name: String, link: String, enabled: Bool = true, source: String? = nil) {
        self.id = id; self.name = name; self.link = link; self.enabled = enabled; self.source = source
    }
}

public struct ParsedServer {
    public var name: String
    public var host: String
    public var port: Int
    public var proto: String
    public var outbound: [String: Any]           // sing-box outbound (without "tag"); Xray outbound when `xrayOnly`
    /// Only Xray can carry this server (e.g. the xhttp transport).
    public var xrayOnly = false
}

public enum ShareLinkError: Error, CustomStringConvertible, Equatable {
    case unsupported(String), malformed(String)
    public var description: String {
        switch self {
        case .unsupported(let s): return "Не поддерживается: \(s)"
        case .malformed(let s): return "Не разобрал ссылку: \(s)"
        }
    }
}

public enum ShareLink {
    /// vless:// trojan:// ss:// hysteria2:// (hy2://) vmess:// — the de-facto standard share formats — and https:// HTTPS proxies.
    public static func parse(_ raw: String) throws -> ParsedServer {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { throw ShareLinkError.malformed("нет схемы") }
        let scheme = text[..<colon].lowercased()
        switch scheme {
        case "vless": return try urlBased(text, proto: "vless")
        case "trojan": return try urlBased(text, proto: "trojan")
        case "hysteria2", "hy2": return try urlBased(text, proto: "hysteria2")
        case "ss": return try shadowsocks(text)
        case "vmess": return try vmess(text)
        case "https": return try httpsProxy(text)
        case "http": throw ShareLinkError.unsupported("незащищённый http:// — нужен https://")
        case "happ": throw ShareLinkError.unsupported("ссылка Happ — вставьте обычную https-ссылку подписки или ссылку на сервер")
        default: throw ShareLinkError.unsupported("схема «\(scheme)://»")
        }
    }

    // MARK: validation of anything that lands in a root-run config

    public static func validHost(_ h: String) -> Bool {
        guard !h.isEmpty, h.count <= 253 else { return false }
        if isIPLiteral(h) { return true }
        return h.range(of: #"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }
    static func safeText(_ s: String, max: Int = 256) -> Bool {
        s.count <= max && !s.unicodeScalars.contains { $0.value < 0x20 || $0 == "\"" || $0 == "\\" }
    }
    static func hex(_ s: String) -> Bool { s.range(of: #"^[0-9A-Fa-f]{0,32}$"#, options: .regularExpression) != nil }

    // MARK: URL-shaped links

    private static func urlBased(_ text: String, proto: String) throws -> ParsedServer {
        guard let c = URLComponents(string: text), let host = c.host, validHost(host) else { throw ShareLinkError.malformed("адрес сервера") }
        let port = c.port ?? 443
        guard (1...65535).contains(port) else { throw ShareLinkError.malformed("порт") }
        let user = c.percentEncodedUser?.removingPercentEncoding ?? c.user ?? ""
        guard !user.isEmpty, safeText(user, max: 128) else { throw ShareLinkError.malformed("ключ/пароль") }
        var q: [String: String] = [:]
        for i in c.queryItems ?? [] { if let v = i.value { q[i.name.lowercased()] = v } }
        func get(_ k: String) -> String? { let v = q[k]; return (v?.isEmpty ?? true) ? nil : v }
        let name = (c.fragment?.removingPercentEncoding).flatMap { safeText($0, max: 80) ? $0 : nil } ?? host

        var o: [String: Any] = ["type": proto, "server": host, "server_port": port]
        var tls: [String: Any] = [:]
        let security = get("security") ?? (proto == "vless" ? "none" : "tls")
        let sni = get("sni") ?? get("peer") ?? host
        guard validHost(sni) else { throw ShareLinkError.malformed("SNI") }

        switch proto {
        case "vless":
            guard UUID(uuidString: user) != nil else { throw ShareLinkError.malformed("UUID") }
            o["uuid"] = user
            if let f = get("flow") { guard ["xtls-rprx-vision"].contains(f) else { throw ShareLinkError.unsupported("flow \(f)") }; o["flow"] = f }
            o["packet_encoding"] = "xudp"
        case "trojan": o["password"] = user
        default:                                                                    // hysteria2
            o["password"] = user
            if let ob = get("obfs") {
                guard ob == "salamander", let pw = get("obfs-password"), safeText(pw, max: 128) else { throw ShareLinkError.unsupported("obfs \(ob)") }
                o["obfs"] = ["type": "salamander", "password": pw]
            }
        }

        if security == "tls" || security == "reality" || proto != "vless" {
            tls = ["enabled": true, "server_name": sni]
            if get("allowinsecure") == "1" || get("insecure") == "1" { tls["insecure"] = true }
            if let alpn = get("alpn") { let list = alpn.split(separator: ",").map(String.init); if list.allSatisfy({ safeText($0, max: 20) }) { tls["alpn"] = list } }
            if let fp = get("fp"), ["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"].contains(fp) {
                tls["utls"] = ["enabled": true, "fingerprint": fp]
            }
            if security == "reality" {
                guard let pbk = get("pbk"), pbk.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else { throw ShareLinkError.malformed("reality public key (нужно 43 символа)") }
                let sid = get("sid") ?? ""
                guard hex(sid) else { throw ShareLinkError.malformed("reality short id") }
                tls["reality"] = ["enabled": true, "public_key": pbk, "short_id": sid]
                if tls["utls"] == nil { tls["utls"] = ["enabled": true, "fingerprint": "chrome"] }
            }
            o["tls"] = tls
        } else if security != "none" { throw ShareLinkError.unsupported("security=\(security)") }

        if proto != "hysteria2" { try applyTransport(&o, type: get("type") ?? "tcp", path: get("path"), host: get("host"), service: get("servicename")) }
        return ParsedServer(name: name, host: host, port: port, proto: proto, outbound: o)
    }

    private static func applyTransport(_ o: inout [String: Any], type: String, path: String?, host: String?, service: String?) throws {
        switch type {
        case "tcp", "": break
        case "ws":
            var t: [String: Any] = ["type": "ws"]
            if let p = path { guard safeText(p) else { throw ShareLinkError.malformed("path") }; t["path"] = p }
            if let h = host { guard validHost(h) else { throw ShareLinkError.malformed("host") }; t["headers"] = ["Host": h] }
            o["transport"] = t
        case "grpc":
            guard let s = service, safeText(s, max: 80) else { throw ShareLinkError.malformed("serviceName") }
            o["transport"] = ["type": "grpc", "service_name": s]
        case "httpupgrade":
            var t: [String: Any] = ["type": "httpupgrade"]
            if let p = path { guard safeText(p) else { throw ShareLinkError.malformed("path") }; t["path"] = p }
            if let h = host { guard validHost(h) else { throw ShareLinkError.malformed("host") }; t["host"] = h }
            o["transport"] = t
        default: throw ShareLinkError.unsupported("транспорт \(type)")
        }
    }

    // MARK: https:// — HTTP CONNECT proxy over TLS

    /// `https://[user[:password]@]host[:port][#name]`. A URL with a path or query is a subscription, not a proxy.
    private static func httpsProxy(_ text: String) throws -> ParsedServer {
        guard let c = URLComponents(string: text), let host = c.host, validHost(host) else { throw ShareLinkError.malformed("адрес прокси") }
        if !(c.path.isEmpty || c.path == "/") || c.query != nil { throw ShareLinkError.unsupported("это ссылка подписки, а не сервер") }
        let port = c.port ?? 443
        guard (1...65535).contains(port) else { throw ShareLinkError.malformed("порт") }
        var o: [String: Any] = ["type": "http", "server": host, "server_port": port, "tls": ["enabled": true, "server_name": host]]
        if let user = c.percentEncodedUser.flatMap({ $0.removingPercentEncoding }), !user.isEmpty {
            guard safeText(user, max: 128) else { throw ShareLinkError.malformed("логин") }
            o["username"] = user
            if let pass = c.percentEncodedPassword.flatMap({ $0.removingPercentEncoding }) {
                guard safeText(pass, max: 128) else { throw ShareLinkError.malformed("пароль") }
                o["password"] = pass
            }
        }
        let name = (c.fragment?.removingPercentEncoding).flatMap { safeText($0, max: 80) && !$0.isEmpty ? $0 : nil } ?? host
        return ParsedServer(name: name, host: host, port: port, proto: "https", outbound: o)
    }

    // MARK: ss:// (SIP002 and the legacy base64 form)

    private static func b64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    private static func shadowsocks(_ text: String) throws -> ParsedServer {
        var body = String(text.dropFirst(5))
        var name: String?
        if let h = body.firstIndex(of: "#") { name = String(body[body.index(after: h)...]).removingPercentEncoding; body = String(body[..<h]) }
        if body.contains("?") { throw ShareLinkError.unsupported("плагины Shadowsocks") }
        var userinfo: String, hostport: String
        if let at = body.lastIndex(of: "@") {
            userinfo = String(body[..<at]); hostport = String(body[body.index(after: at)...])
            if !userinfo.contains(":") { guard let d = b64(userinfo), let s = String(data: d, encoding: .utf8) else { throw ShareLinkError.malformed("userinfo") }; userinfo = s }
            else { userinfo = userinfo.removingPercentEncoding ?? userinfo }
        } else {
            guard let d = b64(body), let s = String(data: d, encoding: .utf8), let at = s.lastIndex(of: "@") else { throw ShareLinkError.malformed("base64") }
            userinfo = String(s[..<at]); hostport = String(s[s.index(after: at)...])
        }
        guard let colon = userinfo.firstIndex(of: ":") else { throw ShareLinkError.malformed("method:password") }
        let method = String(userinfo[..<colon]), password = String(userinfo[userinfo.index(after: colon)...])
        let methods = ["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"]
        guard methods.contains(method) else { throw ShareLinkError.unsupported("метод \(method)") }
        guard safeText(password, max: 128), !password.isEmpty else { throw ShareLinkError.malformed("пароль") }
        guard let hp = URLComponents(string: "ss://" + hostport), let host = hp.host, validHost(host), let port = hp.port, (1...65535).contains(port) else { throw ShareLinkError.malformed("адрес") }
        let n = name.flatMap { safeText($0, max: 80) ? $0 : nil } ?? host
        return ParsedServer(name: n, host: host, port: port, proto: "shadowsocks",
                            outbound: ["type": "shadowsocks", "server": host, "server_port": port, "method": method, "password": password])
    }

    // MARK: vmess:// (base64 JSON)

    private static func vmess(_ text: String) throws -> ParsedServer {
        guard let d = b64(String(text.dropFirst(8))), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw ShareLinkError.malformed("base64/JSON") }
        func str(_ k: String) -> String? { if let s = j[k] as? String, !s.isEmpty { return s }; if let n = j[k] as? Int { return String(n) }; return nil }
        guard let host = str("add"), validHost(host), let port = str("port").flatMap(Int.init), (1...65535).contains(port),
              let id = str("id"), UUID(uuidString: id) != nil else { throw ShareLinkError.malformed("add/port/id") }
        var o: [String: Any] = ["type": "vmess", "server": host, "server_port": port, "uuid": id, "security": str("scy") ?? "auto", "alter_id": str("aid").flatMap(Int.init) ?? 0]
        if ["tls"].contains(str("tls") ?? "") {
            let sni = str("sni") ?? str("host") ?? host
            guard validHost(sni) else { throw ShareLinkError.malformed("SNI") }
            o["tls"] = ["enabled": true, "server_name": sni]
        }
        try applyTransport(&o, type: str("net") ?? "tcp", path: str("path"), host: str("host"), service: str("path"))
        let name = str("ps").flatMap { safeText($0, max: 80) ? $0 : nil } ?? host
        return ParsedServer(name: name, host: host, port: port, proto: "vmess", outbound: o)
    }
}

// MARK: - Persistence

public enum ServerStore {
    public static func load(from dir: URL) -> [ServerEntry] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("servers.json")),
              let list = try? JSONDecoder().decode([ServerEntry].self, from: d) else { return [] }
        return list
    }
    public static func save(_ list: [ServerEntry], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(list) { try? d.write(to: dir.appendingPathComponent("servers.json"), options: .atomic) }
    }
    /// Enabled, usable entries with stable tags `srv-1…`. Bad entries are skipped, never fatal.
    /// Xray-engine servers become a loopback SOCKS hop to the Xray helper (only a port number reaches the config).
    public static func outbounds(_ list: [ServerEntry]) -> [(tag: String, entry: ServerEntry, parsed: ParsedServer)] {
        var out: [(String, ServerEntry, ParsedServer)] = []
        for e in list where e.enabled {
            if e.engine == "xray" {
                guard let port = e.localPort, (1025...65535).contains(port) else { continue }
                let p = ParsedServer(name: e.name, host: "127.0.0.1", port: port, proto: "xray",
                                     outbound: ["type": "socks", "server": "127.0.0.1", "server_port": port, "version": "5", "bind_interface": "lo0"])
                out.append(("srv-\(out.count + 1)", e, p))
            } else if let p = try? ShareLink.parse(e.link) {
                out.append(("srv-\(out.count + 1)", e, p))
            }
        }
        return out
    }

    /// Gives every Xray-engine server a free local port (24100…24999), keeping ports already assigned.
    public static func assignPorts(_ list: inout [ServerEntry]) {
        var used = Set(list.compactMap { $0.engine == "xray" ? $0.localPort : nil })
        for i in list.indices where list[i].engine == "xray" && list[i].localPort == nil {
            if let p = (24100...24999).first(where: { !used.contains($0) }) { list[i].localPort = p; used.insert(p) }
        }
        for i in list.indices where list[i].engine != "xray" { list[i].localPort = nil }
    }
}
