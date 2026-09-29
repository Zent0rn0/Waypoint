import Foundation
import CryptoKit

/// Downloads the community rule lists into `<home>/lists`. Runs in the user's app (never in the root daemon), only when the
/// user has switched "community lists" on, through the VPN client's proxy when it is up (GitHub may be slow or blocked directly).
public enum CommunityListUpdater {
    public struct Report: Sendable {
        public var updated: [String] = []
        public var unchanged: [String] = []
        public var failed: [(id: String, reason: String)] = []
        public var summary: String { "обновлено: \(updated.count), без изменений: \(unchanged.count), ошибок: \(failed.count)" }
    }

    struct Entry: Codable { var sha256: String; var fetched: Date; var bytes: Int }

    public static func listsDirectory(_ home: URL) -> URL { home.appendingPathComponent("lists", isDirectory: true) }

    static func manifest(_ dir: URL) -> [String: Entry] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: Entry].self, from: d)) ?? [:]
    }

    /// Lists that are on disk and valid (what the daemon will pick up).
    public static func installed(home: URL) -> [CommunityList] {
        let dir = listsDirectory(home)
        return CommunityList.all.filter {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent($0.file)) else { return false }
            return CommunityList.hasValidMagic(d)
        }
    }

    public static func refresh(home: URL, socks: (String, UInt16)?, lists: [CommunityList] = CommunityList.all, maxAge: TimeInterval = 20 * 3600,
                               baseOverride: String? = nil, mirrorOverride: String? = nil) async -> Report {
        var report = Report()
        let dir = listsDirectory(home)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mf = manifest(dir)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25; cfg.timeoutIntervalForResource = 90
        if let (h, p) = socks { cfg.connectionProxyDictionary = ["SOCKSEnable": 1, "SOCKSProxy": h, "SOCKSPort": Int(p)] }
        let session = URLSession(configuration: cfg)

        for l in lists {
            let target = dir.appendingPathComponent(l.file)
            if let e = mf[l.id], Date().timeIntervalSince(e.fetched) < maxAge, FileManager.default.fileExists(atPath: target.path) { report.unchanged.append(l.id); continue }
            let urls = [baseOverride.map { $0 + l.path } ?? l.url, mirrorOverride.map { $0 + l.path } ?? l.mirrorURL]
            var data: Data?, why = "нет ответа"
            for u in urls {
                guard let url = URL(string: u) else { continue }
                do {
                    let (d, resp) = try await session.data(from: url)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { why = "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"; continue }
                    guard d.count < 32 * 1024 * 1024 else { why = "слишком большой файл"; continue }
                    guard CommunityList.hasValidMagic(d) else { why = "неверный формат"; continue }
                    data = d; break
                } catch { why = (error as NSError).localizedDescription }
            }
            guard let data else { report.failed.append((l.id, why)); continue }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if mf[l.id]?.sha256 == sha, FileManager.default.fileExists(atPath: target.path) {
                mf[l.id]?.fetched = Date(); report.unchanged.append(l.id)
            } else {
                let tmp = dir.appendingPathComponent(".\(l.file).tmp")
                do { try data.write(to: tmp); _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp) }
                catch { report.failed.append((l.id, "запись: \(error.localizedDescription)")); continue }
                mf[l.id] = Entry(sha256: sha, fetched: Date(), bytes: data.count); report.updated.append(l.id)
            }
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(mf) { try? d.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic) }
        return report
    }
}

// MARK: - Backup

/// One JSON file with everything the user configured: settings, rules, learned verdicts and servers.
public enum Backup {
    struct Bundle: Codable {
        var version = 1
        var created = Date()
        var settings: AppSettings
        var rules: String
        var learned: [LearnedEntry]
        var servers: [ServerEntry]
        var subscriptions: [SubscriptionEntry]?
        var connections: [ConnectionRule]?
    }

    public static func export(home: URL, to url: URL) throws {
        let settings = AppSettings.load(from: home)
        let rules = (try? String(contentsOf: home.appendingPathComponent("rules.txt"), encoding: .utf8)) ?? ""
        let learnedData = try? Data(contentsOf: home.appendingPathComponent("learned.json"))
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let learned = learnedData.flatMap { try? dec.decode([LearnedEntry].self, from: $0) } ?? []
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(Bundle(settings: settings, rules: rules, learned: learned, servers: ServerStore.load(from: home), subscriptions: SubscriptionStore.load(from: home),
                              connections: ConnectionRuleStore.load(from: home))).write(to: url, options: .atomic)
    }

    /// Validates everything before touching the data dir; server links and rules go through the same parsers as normal input.
    public static func restore(from url: URL, home: URL) throws -> String {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let b = try dec.decode(Bundle.self, from: Data(contentsOf: url))
        guard b.version == 1 else { throw UpstreamError("неизвестная версия копии: \(b.version)") }
        let rules = ManualRule.parseAll(b.rules)
        let servers = b.servers.filter { (try? ShareLink.parse($0.link)) != nil || (try? XrayLink.parse($0.link)) != nil }   // Xray-only servers too
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        b.settings.save(to: home)
        try (ManualRule.serialize(rules)).write(to: home.appendingPathComponent("rules.txt"), atomically: true, encoding: .utf8)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(b.learned).write(to: home.appendingPathComponent("learned.json"), options: .atomic)
        ServerStore.save(servers, to: home)
        let subs = (b.subscriptions ?? []).filter { Subscription.isSubscriptionURL($0.url) }
        SubscriptionStore.save(subs, to: home)
        let conns = (b.connections ?? []).compactMap { ConnectionRule(app: $0.app, site: $0.site, target: $0.target) }
        ConnectionRuleStore.save(conns, to: home)
        return "правил: \(rules.count), выученных: \(b.learned.count), серверов: \(servers.count), подписок: \(subs.count), правил соединений: \(conns.count) (пропущено некорректных: \(b.servers.count - servers.count))"
    }
}
