import Foundation

/// Converts the JSON subscription formats (sing-box, Xray) into ordinary share links, so that every server —
/// whatever format it arrived in — passes through the same strict `ShareLink` validation before it can reach a root-run config.
enum JSONSubscription {
    struct Output { var links: [String] = []; var skipped: [String: Int] = [:] }

    static func links(from json: Any) -> Output {
        var out = Output()
        func skip(_ reason: String) { out.skipped[reason, default: 0] += 1 }
        func take(_ outbound: [String: Any], name: String?) {
            if let type = outbound["type"] as? String {                      // sing-box
                if ["selector", "urltest", "direct", "block", "dns"].contains(type) { return }
                do { out.links.append(try singBoxLink(outbound, name: name)) } catch { skip("\(error)") }
            } else if let proto = outbound["protocol"] as? String {         // Xray
                if ["freedom", "blackhole", "dns", "loopback"].contains(proto) { return }
                do { out.links.append(try xrayLink(outbound, name: name)) } catch { skip("\(error)") }
            }
        }
        func config(_ c: [String: Any]) {
            let name = (c["remarks"] as? String) ?? (c["tag"] as? String)
            if let obs = c["outbounds"] as? [[String: Any]] {
                // An Xray full config: the first proxy outbound is the server, the rest is plumbing.
                let isXray = obs.contains { $0["protocol"] != nil }
                if isXray { if let first = obs.first(where: { !["freedom", "blackhole", "dns", "loopback"].contains(($0["protocol"] as? String) ?? "") }) { take(first, name: name) } }
                else { for ob in obs { take(ob, name: ob["tag"] as? String) } }
            } else {
                take(c, name: (c["tag"] as? String) ?? name)
            }
        }
        if let arr = json as? [[String: Any]] { arr.forEach(config) }
        else if let obj = json as? [String: Any] { config(obj) }
        return out
    }

    // MARK: link builders

    private static func url(_ scheme: String, user: String, host: String, port: Int, query: [String: String?], name: String?) throws -> String {
        guard ShareLink.validHost(host), (1...65535).contains(port) else { throw ShareLinkError.malformed("адрес сервера") }
        var c = URLComponents()
        c.scheme = scheme
        c.percentEncodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
        c.host = host
        c.port = port
        let items = query.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { c.queryItems = items }
        c.fragment = name
        guard let s = c.string else { throw ShareLinkError.malformed("ссылка") }
        return s
    }

    // MARK: sing-box

    static func singBoxLink(_ o: [String: Any], name: String?) throws -> String {
        let type = (o["type"] as? String) ?? ""
        guard let host = o["server"] as? String, let port = (o["server_port"] as? NSNumber)?.intValue else { throw ShareLinkError.malformed("адрес сервера") }
        var q: [String: String?] = [:]
        let tls = o["tls"] as? [String: Any]
        if let tls, (tls["enabled"] as? Bool) ?? false {
            q["sni"] = tls["server_name"] as? String
            if (tls["insecure"] as? Bool) == true { q["allowInsecure"] = "1" }
            if let alpn = tls["alpn"] as? [String] { q["alpn"] = alpn.joined(separator: ",") }
            if let u = tls["utls"] as? [String: Any] { q["fp"] = u["fingerprint"] as? String }
            if let r = tls["reality"] as? [String: Any], (r["enabled"] as? Bool) ?? false {
                q["security"] = "reality"; q["pbk"] = r["public_key"] as? String; q["sid"] = r["short_id"] as? String
            } else { q["security"] = "tls" }
        }
        if let t = o["transport"] as? [String: Any], let tt = t["type"] as? String {
            q["type"] = tt
            q["path"] = t["path"] as? String
            q["host"] = ((t["headers"] as? [String: Any])?["Host"] as? String) ?? (t["host"] as? String)
            q["serviceName"] = t["service_name"] as? String
        }
        let label = (o["tag"] as? String) ?? name
        switch type {
        case "vless":
            guard let id = o["uuid"] as? String else { throw ShareLinkError.malformed("UUID") }
            q["flow"] = o["flow"] as? String
            if q["security"] == nil { q["security"] = "none" }
            return try url("vless", user: id, host: host, port: port, query: q, name: label)
        case "trojan":
            guard let pw = o["password"] as? String else { throw ShareLinkError.malformed("пароль") }
            return try url("trojan", user: pw, host: host, port: port, query: q, name: label)
        case "hysteria2":
            guard let pw = o["password"] as? String else { throw ShareLinkError.malformed("пароль") }
            if let ob = o["obfs"] as? [String: Any] { q["obfs"] = ob["type"] as? String; q["obfs-password"] = ob["password"] as? String }
            q["security"] = nil
            return try url("hysteria2", user: pw, host: host, port: port, query: q, name: label)
        case "shadowsocks":
            guard let m = o["method"] as? String, let pw = o["password"] as? String else { throw ShareLinkError.malformed("method/password") }
            if o["plugin"] != nil { throw ShareLinkError.unsupported("плагины Shadowsocks") }
            return try ssLink(method: m, password: pw, host: host, port: port, name: label)
        case "vmess":
            guard let id = o["uuid"] as? String else { throw ShareLinkError.malformed("UUID") }
            return try vmessLink(id: id, aid: (o["alter_id"] as? NSNumber)?.intValue ?? 0, security: o["security"] as? String, host: host, port: port, q: q, name: label)
        default:
            throw ShareLinkError.unsupported("тип «\(type)»")
        }
    }

    // MARK: Xray

    static func xrayLink(_ o: [String: Any], name: String?) throws -> String {
        let proto = (o["protocol"] as? String) ?? ""
        let settings = o["settings"] as? [String: Any] ?? [:]
        let ss = o["streamSettings"] as? [String: Any] ?? [:]
        var q: [String: String?] = [:]
        var network = (ss["network"] as? String) ?? "tcp"
        if network == "raw" { network = "tcp" }
        q["type"] = network
        let security = (ss["security"] as? String) ?? "none"
        q["security"] = security
        if security == "reality", let r = ss["realitySettings"] as? [String: Any] {
            q["pbk"] = r["publicKey"] as? String; q["sid"] = r["shortId"] as? String
            q["sni"] = r["serverName"] as? String; q["fp"] = r["fingerprint"] as? String
        } else if security == "tls", let t = ss["tlsSettings"] as? [String: Any] {
            q["sni"] = t["serverName"] as? String; q["fp"] = t["fingerprint"] as? String
            if let alpn = t["alpn"] as? [String] { q["alpn"] = alpn.joined(separator: ",") }
            if (t["allowInsecure"] as? Bool) == true { q["allowInsecure"] = "1" }
        }
        switch network {
        case "ws":
            let w = ss["wsSettings"] as? [String: Any] ?? [:]
            q["path"] = w["path"] as? String
            q["host"] = ((w["headers"] as? [String: Any])?["Host"] as? String) ?? (w["host"] as? String)
        case "grpc":
            q["serviceName"] = (ss["grpcSettings"] as? [String: Any])?["serviceName"] as? String
        case "httpupgrade":
            let h = ss["httpupgradeSettings"] as? [String: Any] ?? [:]
            q["path"] = h["path"] as? String; q["host"] = h["host"] as? String
        default: break                                   // xhttp, kcp, quic… are rejected by ShareLink with a clear reason
        }
        let label = name ?? (o["tag"] as? String)
        switch proto {
        case "vless":
            guard let vnext = (settings["vnext"] as? [[String: Any]])?.first, let host = vnext["address"] as? String,
                  let port = (vnext["port"] as? NSNumber)?.intValue, let user = (vnext["users"] as? [[String: Any]])?.first,
                  let id = user["id"] as? String else { throw ShareLinkError.malformed("vnext") }
            q["flow"] = user["flow"] as? String
            return try url("vless", user: id, host: host, port: port, query: q, name: label)
        case "vmess":
            guard let vnext = (settings["vnext"] as? [[String: Any]])?.first, let host = vnext["address"] as? String,
                  let port = (vnext["port"] as? NSNumber)?.intValue, let user = (vnext["users"] as? [[String: Any]])?.first,
                  let id = user["id"] as? String else { throw ShareLinkError.malformed("vnext") }
            return try vmessLink(id: id, aid: (user["alterId"] as? NSNumber)?.intValue ?? 0, security: user["security"] as? String, host: host, port: port, q: q, name: label)
        case "trojan":
            guard let srv = (settings["servers"] as? [[String: Any]])?.first, let host = srv["address"] as? String,
                  let port = (srv["port"] as? NSNumber)?.intValue, let pw = srv["password"] as? String else { throw ShareLinkError.malformed("servers") }
            return try url("trojan", user: pw, host: host, port: port, query: q, name: label)
        case "shadowsocks":
            guard let srv = (settings["servers"] as? [[String: Any]])?.first, let host = srv["address"] as? String,
                  let port = (srv["port"] as? NSNumber)?.intValue, let m = srv["method"] as? String, let pw = srv["password"] as? String else { throw ShareLinkError.malformed("servers") }
            return try ssLink(method: m, password: pw, host: host, port: port, name: label)
        default:
            throw ShareLinkError.unsupported("протокол «\(proto)»")
        }
    }

    // MARK: shared

    private static func ssLink(method: String, password: String, host: String, port: Int, name: String?) throws -> String {
        guard ShareLink.validHost(host), (1...65535).contains(port) else { throw ShareLinkError.malformed("адрес сервера") }
        let userinfo = Data("\(method):\(password)".utf8).base64EncodedString()
        let frag = name.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) }.map { "#\($0)" } ?? ""
        return "ss://\(userinfo)@\(host):\(port)\(frag)"
    }

    private static func vmessLink(id: String, aid: Int, security: String?, host: String, port: Int, q: [String: String?], name: String?) throws -> String {
        var j: [String: Any] = ["v": "2", "add": host, "port": String(port), "id": id, "aid": String(aid), "scy": security ?? "auto",
                                "net": (q["type"] ?? nil) ?? "tcp", "ps": name ?? host]
        if let s = q["security"] ?? nil, s == "tls" { j["tls"] = "tls" }
        if let sni = q["sni"] ?? nil { j["sni"] = sni }
        if let p = q["path"] ?? nil { j["path"] = p }
        if let h = q["host"] ?? nil { j["host"] = h }
        if let sn = q["serviceName"] ?? nil { j["path"] = sn }
        let d = try JSONSerialization.data(withJSONObject: j, options: [.sortedKeys])
        return "vmess://" + d.base64EncodedString()
    }
}

// MARK: - Import links of other clients that wrap a plain subscription URL

public enum SubscriptionLink {
    public enum Result: Equatable { case subscription(String), notASubscription, encrypted, insecure }

    /// `happ://add/<url>`, `v2rayn://install-sub?url=`, `sing-box://import-remote-profile?url=`, `clash://install-config?url=`,
    /// `hiddify://import/<url>`, `streisand://import/<url>` → the https URL inside. Encrypted Happ links are refused.
    public static func classify(_ raw: String) -> Result {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("happ://crypt") { return .encrypted }
        var inner: String?
        for prefix in ["happ://add/", "hiddify://import/", "streisand://import/", "karing://install-config?url=", "v2raytun://import/"] where lower.hasPrefix(prefix) {
            inner = String(t.dropFirst(prefix.count))
        }
        if inner == nil, let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(),
           ["v2rayn", "v2rayng", "sing-box", "sfa", "sfi", "sfm", "clash", "clashx", "clash-meta", "clashmeta", "mihomo", "stash", "nekobox", "flclash"].contains(scheme) {
            inner = c.queryItems?.first { $0.name.lowercased() == "url" }?.value
        }
        var candidate = inner ?? t
        if let decoded = candidate.removingPercentEncoding, decoded.lowercased().hasPrefix("http") { candidate = decoded }
        if let hash = candidate.firstIndex(of: "#"), inner != nil { candidate = String(candidate[..<hash]) }     // "#name" of the import link
        let cl = candidate.lowercased()
        if cl.hasPrefix("http://") && inner != nil { return .insecure }
        if Subscription.isSubscriptionURL(candidate) { return .subscription(candidate) }
        if cl.hasPrefix("http://"), let c = URLComponents(string: candidate), c.user == nil, !(c.path.isEmpty || c.path == "/") { return .insecure }
        return .notASubscription
    }
}
