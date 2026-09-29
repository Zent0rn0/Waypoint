import Foundation

/// One active connection as seen by sing-box (Clash-compatible API): which application, where to, by which route.
public struct LiveConnection: Identifiable, Sendable, Equatable {
    public enum Path: String, Sendable { case direct, vpn, race, blocked, unknown }
    public let id: String
    public let host: String
    public let port: Int
    public let network: String
    public let processPath: String?
    public let chain: [String]
    public let rule: String
    public let upload: UInt64
    public let download: UInt64
    public let start: Date

    public var path: Path {
        let c = chain.joined(separator: " ")
        if c.contains("waypoint-race") { return .race }
        if c.contains("direct-phys") { return .direct }
        if c.contains("via-happ") || c.contains("pool-") || c.contains("srv-") { return .vpn }
        if c.contains("REJECT") { return .blocked }
        return .unknown
    }
    /// The server that carries a VPN connection: "srv-2" (your own) or the VPN client itself.
    public var carrier: String? { chain.first { $0.hasPrefix("srv-") } ?? (chain.contains("via-happ") ? "via-happ" : nil) }

    /// `.app` bundle root for GUI applications, else the executable path.
    public var appPath: String? { processPath.map(AppPath.canonical) }

    /// sing-box only sees "waypoint-race" for flows handed to the racer; the racer knows how each one ended
    /// ("direct" / "vpn"). Re-labelling the chain with that outcome makes per-path statistics honest.
    public func resolving(raceOutcome: String?) -> LiveConnection {
        guard path == .race, let o = raceOutcome else { return self }
        let chain = o == "vpn" ? ["via-happ"] : o == "direct" ? ["direct-phys"] : self.chain
        return LiveConnection(id: id, host: host, port: port, network: network, processPath: processPath, chain: chain, rule: rule, upload: upload, download: download, start: start)
    }

    public init(id: String, host: String, port: Int, network: String, processPath: String?, chain: [String], rule: String, upload: UInt64, download: UInt64, start: Date) {
        self.id = id; self.host = host; self.port = port; self.network = network; self.processPath = processPath
        self.chain = chain; self.rule = rule; self.upload = upload; self.download = download; self.start = start
    }
    public var appName: String { appPath.map(AppPath.displayName) ?? "система" }
}

public struct ConnectionsSnapshot: Sendable {
    public var connections: [LiveConnection]
    public var uploadTotal: UInt64
    public var downloadTotal: UInt64
}

public struct PoolInfo: Sendable, Equatable {
    public var tag: String
    public var now: String
    public var members: [String]
    public var delays: [String: Int]      // member → last delay in ms
    public init(tag: String, now: String, members: [String], delays: [String: Int]) { self.tag = tag; self.now = now; self.members = members; self.delays = delays }
}

/// Client for the local sing-box API (loopback + secret). Only used when the tunnel daemon has published its API info.
public final class ClashClient: @unchecked Sendable {
    private let base: URL
    private let secret: String
    private let session: URLSession

    public init(port: UInt16, secret: String) {
        base = URL(string: "http://127.0.0.1:\(port)")!
        self.secret = secret
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.connectionProxyDictionary = [:]            // never through any proxy — this is loopback
        session = URLSession(configuration: c)
    }

    public convenience init?(info: TunnelAPIInfo? = TunnelAPIInfo.read()) {
        guard let info else { return nil }
        self.init(port: info.port, secret: info.secret)
    }

    private func get(_ path: String) async throws -> Any {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (d, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpstreamError("API HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        return try JSONSerialization.jsonObject(with: d)
    }

    static let isoFractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    public func connections() async throws -> ConnectionsSnapshot {
        guard let d = try await get("connections") as? [String: Any] else { throw UpstreamError("bad API reply") }
        let list = (d["connections"] as? [[String: Any]] ?? []).compactMap { c -> LiveConnection? in
            guard let id = c["id"] as? String, let m = c["metadata"] as? [String: Any] else { return nil }
            var proc = m["processPath"] as? String
            if let p = proc, let r = p.range(of: " (", options: .backwards), p.hasSuffix(")") { proc = String(p[..<r.lowerBound]) }   // "/usr/bin/curl (user)"
            if proc?.isEmpty == true { proc = nil }
            let host = (m["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (m["destinationIP"] as? String) ?? "?"
            let port = Int((m["destinationPort"] as? String) ?? "") ?? (m["destinationPort"] as? Int) ?? 0
            let start = (c["start"] as? String).flatMap { Self.isoFractional.date(from: $0) ?? Self.iso.date(from: $0) } ?? Date()
            return LiveConnection(id: id, host: host, port: port, network: (m["network"] as? String) ?? "tcp", processPath: proc,
                                  chain: (c["chains"] as? [String]) ?? [], rule: (c["rule"] as? String) ?? "",
                                  upload: (c["upload"] as? NSNumber)?.uint64Value ?? 0, download: (c["download"] as? NSNumber)?.uint64Value ?? 0, start: start)
        }
        return ConnectionsSnapshot(connections: list, uploadTotal: (d["uploadTotal"] as? NSNumber)?.uint64Value ?? 0,
                                   downloadTotal: (d["downloadTotal"] as? NSNumber)?.uint64Value ?? 0)
    }

    /// Which member of a pool is currently the best, with the last measured delays.
    public func pool(_ tag: String) async throws -> PoolInfo {
        guard let d = try await get("proxies/\(tag)") as? [String: Any] else { throw UpstreamError("bad API reply") }
        var delays: [String: Int] = [:]
        if let h = d["history"] as? [[String: Any]], let last = h.last, let now = d["now"] as? String, let dl = (last["delay"] as? NSNumber)?.intValue { delays[now] = dl }
        return PoolInfo(tag: tag, now: (d["now"] as? String) ?? "?", members: (d["all"] as? [String]) ?? [], delays: delays)
    }

    /// Fresh latency of one outbound to a URL (through that outbound only).
    public func delay(of tag: String, url: String, timeoutMs: Int = 5000) async -> Int? {
        var c = URLComponents(url: base.appendingPathComponent("proxies/\(tag)/delay"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "timeout", value: String(timeoutMs))]
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = Double(timeoutMs) / 1000 + 2
        guard let (d, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (j["delay"] as? NSNumber)?.intValue
    }
}

// MARK: - Traffic accounting (per application and per path), built from snapshot deltas

public struct TrafficStats: Sendable, Equatable {
    public struct Bucket: Sendable, Equatable {
        public var direct: UInt64 = 0, vpn: UInt64 = 0
        public var total: UInt64 { direct + vpn }
        public init(direct: UInt64 = 0, vpn: UInt64 = 0) { self.direct = direct; self.vpn = vpn }
    }
    public var byApp: [String: Bucket] = [:]        // app path → bytes
    public var total = Bucket()
    public var upRate: Double = 0                   // bytes/s over the last interval
    public var downRate: Double = 0
    public init(byApp: [String: Bucket] = [:], total: Bucket = Bucket(), upRate: Double = 0, downRate: Double = 0) {
        self.byApp = byApp; self.total = total; self.upRate = upRate; self.downRate = downRate
    }
}

public final class TrafficTracker: @unchecked Sendable {
    private var last: [String: (up: UInt64, down: UInt64)] = [:]
    private var lastTotals: (up: UInt64, down: UInt64)?
    private var lastTime: Date?
    public private(set) var stats = TrafficStats()
    public init() {}

    /// Feeds one snapshot; attributes only the growth since the previous one. Returns the updated stats.
    @discardableResult
    public func ingest(_ s: ConnectionsSnapshot, at now: Date = Date()) -> TrafficStats {
        var seen = Set<String>()
        for c in s.connections {
            seen.insert(c.id)
            let prev = last[c.id] ?? (0, 0)
            let d = (c.upload >= prev.up ? c.upload - prev.up : c.upload) + (c.download >= prev.down ? c.download - prev.down : c.download)
            last[c.id] = (c.upload, c.download)
            guard d > 0 else { continue }
            let key = c.appPath ?? "system"
            var b = stats.byApp[key] ?? .init()
            switch c.path {
            case .vpn: b.vpn += d; stats.total.vpn += d
            default: b.direct += d; stats.total.direct += d       // race is direct until the racer sends it elsewhere; blocked has no bytes
            }
            stats.byApp[key] = b
        }
        last = last.filter { seen.contains($0.key) }
        if let lt = lastTotals, let t = lastTime, now.timeIntervalSince(t) > 0.2 {
            let dt = now.timeIntervalSince(t)
            stats.upRate = Double(s.uploadTotal >= lt.up ? s.uploadTotal - lt.up : 0) / dt
            stats.downRate = Double(s.downloadTotal >= lt.down ? s.downloadTotal - lt.down : 0) / dt
        }
        lastTotals = (s.uploadTotal, s.downloadTotal); lastTime = now
        return stats
    }
}
