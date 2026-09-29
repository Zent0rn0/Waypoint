import Foundation
import Network

/// Checks every server for real, with no root and without touching the running tunnel: a private sing-box exposes one
/// local SOCKS port per server; whatever sing-box cannot carry is retried through a private Xray. Each port is used to
/// load Cloudflare's trace page, which yields: does it work, how fast, and which country websites actually see.
public enum ServerAudit {
    public struct Result: Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var ok: Bool
        public var ms: Int?
        public var country: String?
        public var error: String?
        /// Which engine carried it: "sing-box" or "xray" (nil when neither worked).
        public var engine: String?
    }

    public static func run(servers: [ServerEntry], singBox: URL, xray: URL?, interface: String, directDNS: String,
                           logTo: URL? = nil, tlsExtra: [String: Any] = [:]) async -> [Result] {
        guard TunnelConfig.isValidInterface(interface), ipv4Value(directDNS) != nil else { return [] }
        var results: [String: Result] = [:]

        // 1. sing-box
        let sbCandidates = servers.filter { (try? ShareLink.parse($0.link)) != nil }
        let base = UInt16.random(in: 30000...40000)
        let first = await singBoxPass(sbCandidates, binary: singBox, interface: interface, dns: directDNS, base: base, logTo: logTo, tlsExtra: tlsExtra)
        for r in first { results[r.id] = r }

        // 2. Xray for everything sing-box could not carry
        if let xray, FileManager.default.isExecutableFile(atPath: xray.path) {
            let retry = servers.filter { results[$0.id]?.ok != true && (try? XrayLink.parse($0.link)) != nil }
            let second = await xrayPass(retry, binary: xray, interface: interface, base: base + 2000)
            for r in second where r.ok || results[r.id] == nil { results[r.id] = r }
        }
        for s in servers where results[s.id] == nil {
            results[s.id] = Result(id: s.id, name: s.name, ok: false, ms: nil, country: nil, error: "не поддерживается", engine: nil)
        }
        return servers.compactMap { results[$0.id] }
    }

    // MARK: passes

    private static func singBoxPass(_ servers: [ServerEntry], binary: URL, interface: String, dns: String, base: UInt16,
                                    logTo: URL?, tlsExtra: [String: Any]) async -> [Result] {
        guard !servers.isEmpty else { return [] }
        var inbounds: [[String: Any]] = [], outbounds: [[String: Any]] = [], rules: [[String: Any]] = []
        var slots: [(ServerEntry, UInt16)] = []
        for (i, e) in servers.enumerated() {
            guard let p = try? ShareLink.parse(e.link) else { continue }
            let port = base + UInt16(i)
            var o = p.outbound; o["tag"] = "s\(i)"
            if !tlsExtra.isEmpty, var tls = o["tls"] as? [String: Any] { for (k, v) in tlsExtra { tls[k] = v }; o["tls"] = tls }
            outbounds.append(o)
            inbounds.append(["type": "mixed", "tag": "in\(i)", "listen": "127.0.0.1", "listen_port": Int(port)])
            rules.append(["inbound": ["in\(i)"], "action": "route", "outbound": "s\(i)"])
            slots.append((e, port))
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        let cfg: [String: Any] = [
            "log": ["level": logTo == nil ? "error" : "debug", "timestamp": true],
            "dns": ["servers": [["type": "udp", "tag": "d", "server": dns, "bind_interface": interface]], "final": "d"],
            "inbounds": inbounds, "outbounds": outbounds,
            // Dial through the real NIC: the result must not depend on whatever VPN is up right now.
            "route": ["rules": rules, "final": "direct", "default_interface": interface, "default_domain_resolver": "d"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: cfg) else { return [] }
        return await withHelper(binary: binary, args: { ["run", "-c", $0] }, config: data, logTo: logTo, firstPort: slots.first?.1) {
            await probe(slots, engine: "sing-box")
        } ?? slots.map { Result(id: $0.0.id, name: $0.0.name, ok: false, ms: nil, country: nil, error: "не запустился sing-box", engine: nil) }
    }

    private static func xrayPass(_ servers: [ServerEntry], binary: URL, interface: String, base: UInt16) async -> [Result] {
        guard !servers.isEmpty else { return [] }
        let items = servers.enumerated().map { (port: Int(base) + $0.offset, link: $0.element.link) }
        guard let data = XrayLink.config(items, interface: interface, logLevel: "error") else { return [] }
        let slots = servers.enumerated().map { ($0.element, base + UInt16($0.offset)) }
        return await withHelper(binary: binary, args: { ["run", "-c", $0] }, config: data, logTo: nil, firstPort: slots.first?.1) {
            await probe(slots, engine: "xray")
        } ?? []
    }

    // MARK: helpers

    private static func withHelper(binary: URL, args: (String) -> [String], config: Data, logTo: URL?, firstPort: UInt16?,
                                   body: () async -> [Result]) async -> [Result]? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-audit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        guard (try? config.write(to: url)) != nil else { return nil }
        let p = Process()
        p.executableURL = binary
        p.arguments = args(url.path)
        if let logTo { FileManager.default.createFile(atPath: logTo.path, contents: nil); let h = FileHandle(forWritingAtPath: logTo.path); p.standardOutput = h; p.standardError = h }
        else { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice }
        do { try p.run() } catch { return nil }
        defer { p.terminate() }
        if let fp = firstPort {
            for _ in 0..<40 where !(await Probe.tcpOpen(host: "127.0.0.1", port: fp, timeoutMs: 200)) { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        return await body()
    }

    private static func probe(_ slots: [(ServerEntry, UInt16)], engine: String) async -> [Result] {
        var results: [Result] = []
        await withTaskGroup(of: Result.self) { g in
            var running = 0
            for (e, port) in slots {
                if running >= 8, let r = await g.next() { results.append(r); running -= 1 }
                running += 1
                g.addTask {
                    let t0 = Date()
                    switch await Probe.httpsGet(host: "www.cloudflare.com", path: "/cdn-cgi/trace", via: .socks(host: "127.0.0.1", port: port), timeoutMs: 10000) {
                    case .success(let h):
                        let ms = Int(Date().timeIntervalSince(t0) * 1000)
                        let ok = h.status == 200
                        return Result(id: e.id, name: e.name, ok: ok, ms: ms, country: Diagnostics.cloudflareLoc(h.text), error: ok ? nil : "HTTP \(h.status)", engine: ok ? engine : nil)
                    case .failure(let err):
                        let t = "\(err)"
                        return Result(id: e.id, name: e.name, ok: false, ms: nil, country: nil,
                                      error: t.contains("imeout") ? "не отвечает" : (t.contains("22") ? "сервер не принял подключение" : String(t.prefix(60))), engine: nil)
                    }
                }
            }
            for await r in g { results.append(r) }
        }
        return results
    }
}
