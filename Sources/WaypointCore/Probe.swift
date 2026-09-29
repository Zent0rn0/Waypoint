import Foundation
import Network
import Security

/// Real TLS handshakes with SNI, used for background revalidation and for `waypoint check`.
/// Certificates are deliberately not validated: the question is "can I reach a TLS server for this name",
/// not "is it trustworthy" — an interceptor answering with a wrong certificate is still a *block* signal
/// that we want to see as a handshake success on the VPN path and (usually) a reset on the direct one.
public enum Probe {
    public enum Path: Sendable {
        case direct(NWInterface?)
        case socks(host: String, port: UInt16)
    }

    public static func tlsHandshake(host: String, port: UInt16 = 443, path: Path, timeoutMs: Int = 5000) async -> Result<Int, Error> {
        let started = Date()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, .global())
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())

        switch path {
        case .direct(let iface):
            if let iface, !isLoopback(host) { params.requiredInterface = iface }
        case .socks(let h, let p):
            guard let port = NWEndpoint.Port(rawValue: p) else { return .failure(UpstreamError("bad proxy port")) }
            let ctx = NWParameters.PrivacyContext(description: "waypoint-probe")
            ctx.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(h), port: port))]
            params.setPrivacyContext(ctx)
        }

        guard let ep = NWEndpoint.Port(rawValue: port) else { return .failure(UpstreamError("bad port")) }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: ep, using: params)
        defer { conn.cancel() }
        do {
            try await withTimeout(ms: timeoutMs) { try await conn.awaitReady() }
            return .success(Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return .failure(error)
        }
    }

    public struct Comparison: Sendable {
        public var direct: Result<Int, Error>
        public var vpn: Result<Int, Error>?
        public var verdict: String
    }

    /// Tries both paths in parallel and explains what it sees.
    public static func compare(host: String, interface: NWInterface?, upstream: (String, UInt16)?) async -> Comparison {
        async let d = tlsHandshake(host: host, path: .direct(interface))
        async let v: Result<Int, Error>? = {
            guard let (h, p) = upstream else { return nil }
            return await tlsHandshake(host: host, path: .socks(host: h, port: p))
        }()
        let (dr, vr) = await (d, v)
        let verdict: String
        switch (dr, vr) {
        case (.success, _): verdict = "напрямую работает — VPN не нужен"
        case (.failure, .some(.success)): verdict = "напрямую не открывается, через VPN — да → маршрут: VPN"
        case (.failure, .some(.failure)): verdict = "не открывается ни так, ни так (сайт недоступен или VPN-канал не работает)"
        case (.failure, .none): verdict = "напрямую не открывается; VPN-апстрим не задан, сравнить не с чем"
        }
        return Comparison(direct: dr, vpn: vr, verdict: verdict)
    }

    /// Plain TCP reachability (used for "is the racer listening?").
    public static func tcpOpen(host: String, port: UInt16, timeoutMs: Int = 400) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else { return false }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        defer { c.cancel() }
        return (try? await withTimeout(ms: timeoutMs) { try await c.awaitReady(); return true }) ?? false
    }

    // MARK: plain HTTPS GET over a chosen path (diagnostics: exit region, TikTok, IP echo)

    public struct HTTPResult: Sendable {
        public var status: Int
        public var body: Data
        public var ms: Int
        public var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// GET https://host/path with the chosen path pinned. Certificates are not validated (same reasoning as `tlsHandshake`).
    public static func httpsGet(host: String, path: String = "/", via: Path, timeoutMs: Int = 10000, maxBytes: Int = 600_000) async -> Result<HTTPResult, Error> {
        let started = Date()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, .global())
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        switch via {
        case .direct(let iface): if let iface { params.requiredInterface = iface }
        case .socks(let h, let p):
            guard let port = NWEndpoint.Port(rawValue: p) else { return .failure(UpstreamError("bad proxy port")) }
            let ctx = NWParameters.PrivacyContext(description: "waypoint-http")
            ctx.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(h), port: port))]
            params.setPrivacyContext(ctx)
        }
        guard let ep = NWEndpoint.Port(rawValue: 443) else { return .failure(UpstreamError("bad port")) }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: ep, using: params)
        defer { conn.cancel() }
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        let request = Data("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: \(ua)\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n".utf8)
        do {
            return try await withTimeout(ms: timeoutMs) {
                try await conn.awaitReady()
                try await conn.sendAsync(request)
                var buf = Data()
                while buf.count < maxBytes {
                    let (d, eof) = try await conn.receiveAsync()
                    if eof { break }
                    buf.append(d)
                }
                guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { throw BadFirstResponse(reason: "no HTTP head") }
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                let code = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
                return .success(HTTPResult(status: code, body: Data(buf[r.upperBound...]), ms: Int(Date().timeIntervalSince(started) * 1000)))
            }
        } catch { return .failure(error) }
    }
}
