import Foundation

// MARK: - Subscriptions (https:// links from a VPN provider that return a list of servers)

/// Traffic quota and expiry a provider reports in the `subscription-userinfo` header.
public struct SubscriptionInfo: Codable, Equatable, Sendable {
    public var upload: UInt64?
    public var download: UInt64?
    public var total: UInt64?          // 0 or nil = unlimited
    public var expire: Date?
    public var used: UInt64 { (upload ?? 0) + (download ?? 0) }
    public init(upload: UInt64? = nil, download: UInt64? = nil, total: UInt64? = nil, expire: Date? = nil) {
        self.upload = upload; self.download = download; self.total = total; self.expire = expire
    }

    /// `upload=123; download=456; total=789; expire=1700000000`
    public static func parse(header: String) -> SubscriptionInfo? {
        var i = SubscriptionInfo(), any = false
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard kv.count == 2, let v = Double(kv[1]), v >= 0, v < 1e19 else { continue }
            switch kv[0] {
            case "upload": i.upload = UInt64(v); any = true
            case "download": i.download = UInt64(v); any = true
            case "total": i.total = UInt64(v); any = true
            case "expire": if v > 0 { i.expire = Date(timeIntervalSince1970: v) }; any = true
            default: break
            }
        }
        return any ? i : nil
    }
}

public struct SubscriptionEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var url: String
    public var title: String?
    public var updated: Date?
    public var error: String?
    public var servers: Int
    public var skipped: Int
    public var skippedReasons: [String]?
    public var info: SubscriptionInfo?
    /// Hours between updates the provider asked for (`profile-update-interval`), if any.
    public var updateHours: Int?
    public init(id: String = UUID().uuidString, url: String) {
        self.id = id; self.url = url; self.servers = 0; self.skipped = 0
    }
    public var name: String { title ?? URL(string: url)?.host ?? "Подписка" }
    /// `hours`: the user's own refresh interval; without it the provider's hint (or 12 h) applies.
    public func isStale(now: Date = Date(), hours userHours: Int? = nil) -> Bool {
        guard let updated else { return true }
        let hours = min(max(userHours ?? updateHours ?? 12, 1), 72)
        return now.timeIntervalSince(updated) > Double(hours) * 3600
    }
}

public enum SubscriptionError: Error, CustomStringConvertible, Equatable {
    case notHTTPS, http(Int), tooLarge, html, json, clash, empty, unreadable, network(String)
    public var description: String {
        switch self {
        case .notHTTPS: return "нужна защищённая ссылка https://"
        case .http(let c): return c == 401 || c == 403 || c == 404 ? "провайдер отказал (HTTP \(c)): ссылка устарела или привязана к другому приложению" : "провайдер ответил HTTP \(c)"
        case .tooLarge: return "слишком большой ответ"
        case .html: return "по ссылке веб-страница, а не список серверов — возьмите у провайдера ссылку подписки"
        case .json: return "провайдер отдал JSON-конфигурацию, а нужен список ссылок (vless://, trojan://…)"
        case .clash: return "провайдер отдал конфигурацию Clash, а нужен список ссылок"
        case .empty: return "в ответе нет ни одной ссылки на сервер"
        case .unreadable: return "ответ не читается как текст"
        case .network(let s): return "не удалось загрузить: \(s)"
        }
    }
}

public enum Subscription {
    /// Deliberately neutral: panels (Remnawave, Marzban…) pick the format by User-Agent, and a plain list of links —
    /// what they send to unknown clients — is the most complete. Nothing here pretends to be another app.
    public static let userAgent = "Waypoint/0.2"
    public static let maxBytes = 5 * 1024 * 1024
    /// Servers enabled by default per subscription (the rest are added switched off: every enabled server is probed).
    public static let defaultEnabledLimit = 40

    /// `https://…` with a path or a token, and no `user@` — a subscription, not an HTTPS proxy.
    public static func isSubscriptionURL(_ raw: String) -> Bool {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty else { return false }
        if c.user != nil || c.password != nil { return false }
        return !(c.path.isEmpty || c.path == "/") || (c.query?.isEmpty == false)
    }

    // MARK: body

    /// Share links from a subscription body: plain text or base64 (standard / URL-safe, with or without padding).
    static func lines(from data: Data) throws -> [String] {
        guard var text = String(data: data, encoding: .utf8) else { throw SubscriptionError.unreadable }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SubscriptionError.empty }
        let head = text.prefix(300).lowercased()
        if head.hasPrefix("<") || head.contains("<html") || head.contains("<!doctype") { throw SubscriptionError.html }

        if head.hasPrefix("proxies:") || head.hasPrefix("port:") || head.hasPrefix("mixed-port:") || text.contains("\nproxies:") { throw SubscriptionError.clash }
        if !text.contains("://") {
            var b = text.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            guard let d = Data(base64Encoded: b), let decoded = String(data: d, encoding: .utf8), decoded.contains("://") else { throw SubscriptionError.empty }
            text = decoded
        }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
    }

    public struct ParseResult {
        public var servers: [(link: String, server: ParsedServer)] = []
        public var skipped: [String: Int] = [:]          // reason → count
        public var skippedCount: Int { skipped.values.reduce(0, +) }
    }

    /// Every server goes through the same strict parser as a hand-pasted link; anything it rejects is counted, never used.
    /// JSON subscriptions (sing-box, Xray) are first converted into share links for exactly that reason.
    public static func parse(_ data: Data) throws -> ParseResult {
        var r = ParseResult(), seen = Set<String>()
        var candidates: [String]
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { throw SubscriptionError.json }
            let out = JSONSubscription.links(from: json)
            candidates = out.links
            r.skipped = out.skipped
        } else {
            candidates = try lines(from: data)
        }
        for line in candidates where seen.insert(line).inserted {
            do { r.servers.append((line, try ShareLink.parse(line))) }
            catch {
                // Not for sing-box (e.g. xhttp)? Xray may carry it.
                if let x = try? XrayLink.parse(line) { r.servers.append((line, x)) } else { r.skipped["\(error)", default: 0] += 1 }
            }
        }
        if r.servers.isEmpty && r.skipped.isEmpty { throw SubscriptionError.empty }
        return r
    }

    static func decodeTitle(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("base64:"), let d = Data(base64Encoded: String(t.dropFirst(7))), let s = String(data: d, encoding: .utf8) { t = s }
        t = (t.removingPercentEncoding ?? t).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, ShareLink.safeText(t, max: 80) else { return nil }
        return t
    }

    // MARK: fetch

    public struct FetchResult {
        public var parsed: ParseResult
        public var info: SubscriptionInfo?
        public var title: String?
        public var updateHours: Int?
    }

    /// Downloads a subscription the honest way: our own User-Agent, no device-id headers. Through the VPN client's proxy when
    /// given (the provider's domain may be unreachable directly). `allowLoopbackHTTP` exists for tests only.
    public static func fetch(_ urlString: String, socks: (String, UInt16)?, allowLoopbackHTTP: Bool = false) async throws -> FetchResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host else { throw SubscriptionError.notHTTPS }
        let loopback = host == "127.0.0.1" || host == "localhost"
        guard scheme == "https" || (allowLoopbackHTTP && loopback && scheme == "http") else { throw SubscriptionError.notHTTPS }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 45
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "*/*"]
        if let (h, p) = socks, !loopback { cfg.connectionProxyDictionary = ["SOCKSEnable": 1, "SOCKSProxy": h, "SOCKSPort": Int(p)] }
        else { cfg.connectionProxyDictionary = [:] }
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: url) }
        catch { throw SubscriptionError.network((error as NSError).localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw SubscriptionError.network("нет ответа") }
        guard (200..<300).contains(http.statusCode) else { throw SubscriptionError.http(http.statusCode) }
        if let final = http.url, final.scheme?.lowercased() != "https", !(allowLoopbackHTTP && loopback) { throw SubscriptionError.notHTTPS }   // redirected to http
        guard data.count <= maxBytes else { throw SubscriptionError.tooLarge }

        let parsed = try parse(data)
        let info = http.value(forHTTPHeaderField: "subscription-userinfo").flatMap(SubscriptionInfo.parse(header:))
        var title = http.value(forHTTPHeaderField: "profile-title").flatMap(decodeTitle)
        if title == nil, let cd = http.value(forHTTPHeaderField: "content-disposition"), let r = cd.range(of: "filename=") {
            title = decodeTitle(String(cd[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"; ")))
        }
        let hours = http.value(forHTTPHeaderField: "profile-update-interval").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return FetchResult(parsed: parsed, info: info, title: title, updateHours: hours)
    }

    // MARK: helpers

    /// Servers that exit inside Russia gain nothing for blocked sites (and make TikTok see a Russian region), so in the Russian
    /// region they are added switched off. Judged by the name providers give them.
    public static func looksRussian(_ name: String) -> Bool {
        if name.contains("🇷🇺") { return true }
        let n = name.lowercased()
        if ["росси", "russia", "москв", "moscow", "санкт", "петербург", "spb", "новосиб", "novosib", "екатеринб", "yekaterinb"].contains(where: n.contains) { return true }
        return n.split(whereSeparator: { !$0.isLetter }).contains("ru")
    }

    /// Merge a fresh server list into the stored one: keeps ids and the user's on/off choice for links seen before.
    public static func merge(existing: [ServerEntry], subscription id: String, fresh: [(link: String, server: ParsedServer)], region: Region) -> [ServerEntry] {
        let old = Dictionary(existing.filter { $0.source == id }.map { ($0.link, $0) }, uniquingKeysWith: { a, _ in a })
        var enabledNew = 0
        let merged: [ServerEntry] = fresh.map { item in
            if var e = old[item.link] { e.name = item.server.name; return e }
            var on = !(region == .russia && looksRussian(item.server.name))
            if on { enabledNew += 1; if enabledNew > defaultEnabledLimit { on = false } }
            var e = ServerEntry(name: item.server.name, link: item.link, enabled: on, source: id)
            if item.server.xrayOnly { e.engine = "xray" }
            return e
        }
        var all = existing.filter { $0.source != id } + merged
        ServerStore.assignPorts(&all)
        return all
    }
}

public enum SubscriptionStore {
    public static func load(from dir: URL) -> [SubscriptionEntry] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("subscriptions.json")) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([SubscriptionEntry].self, from: d)) ?? []
    }
    public static func save(_ list: [SubscriptionEntry], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(list) { try? d.write(to: dir.appendingPathComponent("subscriptions.json"), options: .atomic) }
    }
}
