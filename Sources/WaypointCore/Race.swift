import Foundation
import Network

public enum PathKind: String, Sendable, Codable { case direct, vpn }

// MARK: - Dialers

protocol PathDialer: Sendable {
    /// Returns a connection that is ready to carry application bytes to host:port.
    func dial(host: String, port: UInt16, deadlineMs: Int) async throws -> NWConnection
}

/// Straight to the destination, pinned to the physical interface (IP_BOUND_IF under the hood).
/// Pinning is what lets us bypass a full-tunnel VPN whose utun owns the default route — without root.
struct DirectDialer: PathDialer {
    let interface: @Sendable () -> NWInterface?

    func dial(host: String, port: UInt16, deadlineMs: Int) async throws -> NWConnection {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = max(2, deadlineMs / 1000)
        }
        if !isLoopback(host), let iface = interface() { params.requiredInterface = iface }
        guard let p = NWEndpoint.Port(rawValue: port) else { throw UpstreamError("bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        do { try await conn.awaitReady() } catch { conn.cancel(); throw error }
        return conn
    }
}

/// Through the user's VPN client, via its local SOCKS5 inbound (Happ/Xray: 127.0.0.1:10808).
/// The hostname is handed over unresolved, so DNS happens on the far side (no poisoning, no leak).
struct UpstreamDialer: PathDialer {
    let host: String
    let port: UInt16
    /// Optional hook, e.g. "start the VPN if it is off". Called once when the upstream refuses connections.
    var prepare: (@Sendable () async -> Void)?

    func dial(host target: String, port targetPort: UInt16, deadlineMs: Int) async throws -> NWConnection {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw UpstreamError("bad upstream port") }
        var conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        do {
            try await conn.awaitReady()
        } catch {
            conn.cancel()
            guard let prepare else { throw UpstreamError("VPN upstream \(host):\(port) недоступен (\(error))") }
            await prepare()
            conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            do { try await conn.awaitReady() } catch { conn.cancel(); throw UpstreamError("VPN upstream \(host):\(port) недоступен (\(error))") }
        }
        do {
            try await Socks5.clientHandshake(conn, host: target, port: targetPort)
            return conn
        } catch {
            conn.cancel()
            throw error
        }
    }
}

// MARK: - SOCKS5 client

enum Socks5 {
    static func connectRequest(host: String, port: UInt16) -> Data {
        var d = Data([0x05, 0x01, 0x00])
        if let v4 = ipv4Value(host) {
            d.append(0x01)
            d.append(contentsOf: [UInt8(v4 >> 24), UInt8((v4 >> 16) & 0xff), UInt8((v4 >> 8) & 0xff), UInt8(v4 & 0xff)])
        } else if isIPv6Literal(host) {
            var a = in6_addr()
            inet_pton(AF_INET6, host, &a)
            d.append(0x04)
            withUnsafeBytes(of: &a) { d.append(contentsOf: $0) }
        } else {
            let b = Array(host.utf8.prefix(255))
            d.append(0x03)
            d.append(UInt8(b.count))
            d.append(contentsOf: b)
        }
        d.append(UInt8(port >> 8))
        d.append(UInt8(port & 0xff))
        return d
    }

    static func clientHandshake(_ conn: NWConnection, host: String, port: UInt16) async throws {
        let r = BufferedReader(conn)
        try await conn.sendAsync(Data([0x05, 0x01, 0x00]))
        let m = try await r.readExactly(2)
        guard m[m.startIndex] == 0x05, m[m.startIndex + 1] == 0x00 else {
            throw UpstreamError("SOCKS5 upstream требует авторизацию или не SOCKS5")
        }
        try await conn.sendAsync(connectRequest(host: host, port: port))
        let h = try await r.readExactly(4)
        guard h[h.startIndex + 1] == 0x00 else { throw UpstreamError("SOCKS5 upstream отказал (код \(h[h.startIndex + 1]))") }
        switch h[h.startIndex + 3] {
        case 0x01: _ = try await r.readExactly(4 + 2)
        case 0x04: _ = try await r.readExactly(16 + 2)
        case 0x03:
            let l = try await r.readExactly(1)
            _ = try await r.readExactly(Int(l[l.startIndex]) + 2)
        default: throw UpstreamError("SOCKS5: неизвестный тип адреса")
        }
        // Anything the upstream already sent beyond the reply would be lost with the reader; SOCKS5
        // servers do not send application data before the client speaks, so the buffer is empty here.
    }
}

// MARK: - Validating the first server bytes

/// A path only "wins" if what came back looks like the protocol we expect. This is what turns a
/// hijacked DNS answer, a block-page IP or a middlebox RST into a *failure* instead of a "success".
enum FirstResponse {
    static func isTLSPort(_ port: UInt16) -> Bool { port == 443 || port == 8443 }

    static func validate(_ d: Data, port: UInt16) throws {
        let b = [UInt8](d.prefix(16))
        guard !b.isEmpty else { throw BadFirstResponse(reason: "empty") }
        if isTLSPort(port) {
            // TLS record: handshake (0x16) or alert (0x15), major version 3. An alert still proves a real server answered.
            guard (b[0] == 0x16 || b[0] == 0x15), b.count >= 2, b[1] == 0x03 else {
                throw BadFirstResponse(reason: "not a TLS record")
            }
        } else if port == 80 || port == 8080 {
            guard b.starts(with: Array("HTTP/".utf8)) else { throw BadFirstResponse(reason: "not HTTP") }
            if isBlockpageRedirect(d) { throw BadFirstResponse(reason: "ISP block page") }
        }
    }

    /// Plain-HTTP redirects to well-known ISP/regulator stub pages count as "blocked".
    static func isBlockpageRedirect(_ d: Data) -> Bool {
        let head = String(decoding: d.prefix(2048), as: UTF8.self)
        guard head.hasPrefix("HTTP/1.") else { return false }
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("location:") {
            let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
            guard let host = URL(string: value)?.host?.lowercased() else { continue }
            if host == "warning.rt.ru" || host.hasSuffix("rkn.gov.ru") || host.hasPrefix("blocked.") { return true }
        }
        return false
    }
}

// MARK: - What must be replayed with an HTTP request

/// A server does not answer a POST until it has the body, so a race on plain HTTP can only be decided
/// if the first flight contains the whole request. Small fixed-length bodies are included; everything
/// else (chunked, huge, `Expect: 100-continue`) skips the race and falls back sequentially.
enum HTTPBodyPlan: Equatable {
    case none
    case fixed(Int)
    case unsuitable

    static let maxReplayBody = 256 * 1024

    static func parse(head: Data) -> HTTPBodyPlan {
        let text = String(decoding: head, as: UTF8.self)
        var length: Int?
        var chunked = false, expect = false
        for line in text.split(separator: "\r\n").dropFirst() {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") {
                length = Int(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            } else if l.hasPrefix("transfer-encoding:") && l.contains("chunked") {
                chunked = true
            } else if l.hasPrefix("expect:") && l.contains("100-continue") {
                expect = true
            }
        }
        if chunked || expect { return .unsuitable }
        guard let n = length else { return .none }
        if n == 0 { return .none }
        return n <= maxReplayBody ? .fixed(n) : .unsuitable
    }
}

// MARK: - The race

public struct RaceConfig: Sendable, Equatable {
    /// Head start given to the direct path before the VPN path is also tried.
    public var hedgeMs = 900
    public var directDeadlineMs = 5000
    public var vpnDeadlineMs = 12000
    public init(hedgeMs: Int = 900, directDeadlineMs: Int = 5000, vpnDeadlineMs: Int = 12000) {
        self.hedgeMs = hedgeMs
        self.directDeadlineMs = directDeadlineMs
        self.vpnDeadlineMs = vpnDeadlineMs
    }
}

struct RaceResult {
    enum DirectOutcome { case ok, hardFailure(Error), stalled, notFinished }
    var winner: PathKind?
    var connection: NWConnection?
    var firstBytes = Data()
    var direct: DirectOutcome = .notFinished
    var vpnError: Error?
    var elapsedMs = 0
}

/// Optimistic dual-path dialing with transparent replay.
///
/// The client has already been told "connected" and has sent its first flight (a TLS ClientHello or
/// an HTTP request). We buffer it and try the direct path first. If direct fails fast, or has not
/// produced a plausible reply within `hedgeMs`, the *same bytes* are replayed through the VPN path.
/// Whichever path returns a valid server reply first wins; the loser is torn down. Because no server
/// byte reached the client before the winner was chosen, the client cannot tell a replay happened.
struct Racer {
    let direct: PathDialer
    let vpn: PathDialer
    let config: RaceConfig

    typealias Attempt = (NWConnection, Data)

    private func attempt(_ dialer: PathDialer, host: String, port: UInt16, initial: Data, deadlineMs: Int) async throws -> Attempt {
        try await withTimeout(ms: deadlineMs) {
            let conn = try await dialer.dial(host: host, port: port, deadlineMs: deadlineMs)
            do {
                try await conn.sendAsync(initial)
                let (d, eof) = try await conn.receiveAsync()
                if eof || d.isEmpty { throw EOFError() }
                try FirstResponse.validate(d, port: port)
                return (conn, d)
            } catch {
                conn.cancel()
                throw error
            }
        }
    }

    func run(host: String, port: UInt16, initial: Data) async -> RaceResult {
        let started = Date()
        enum Ev { case direct, vpn, hedge }
        let (events, cont) = AsyncStream.makeStream(of: Ev.self)

        let dTask = Task { () -> Result<Attempt, Error> in
            let r = await capture { try await attempt(direct, host: host, port: port, initial: initial, deadlineMs: config.directDeadlineMs) }
            cont.yield(.direct)
            return r
        }
        let hedgeTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(config.hedgeMs) * 1_000_000)
            if !Task.isCancelled { cont.yield(.hedge) }
        }
        var vTask: Task<Result<Attempt, Error>, Never>?
        func startVPN() {
            vTask = Task { () -> Result<Attempt, Error> in
                let r = await capture { try await attempt(vpn, host: host, port: port, initial: initial, deadlineMs: config.vpnDeadlineMs) }
                cont.yield(.vpn)
                return r
            }
        }

        var dResult: Result<Attempt, Error>?
        var vResult: Result<Attempt, Error>?
        var result = RaceResult()

        loop: for await ev in events {
            switch ev {
            case .hedge:
                if vTask == nil { startVPN() }
            case .direct:
                let r = await dTask.value
                dResult = r
                if case .success(let a) = r {
                    result.winner = .direct; result.connection = a.0; result.firstBytes = a.1
                    break loop
                }
                if vTask == nil { startVPN() }                       // failed early: don't wait for the hedge timer
                else if case .failure = vResult { break loop }        // both failed
            case .vpn:
                let r = await vTask!.value
                vResult = r
                if case .success(let a) = r {
                    result.winner = .vpn; result.connection = a.0; result.firstBytes = a.1
                    break loop
                }
                if case .failure = dResult { break loop }             // both failed
            }
        }
        hedgeTask.cancel()
        cont.finish()

        // Tear down whoever lost (and close any connection a loser managed to open in the meantime).
        var directStillRunning = false
        if dResult == nil {
            directStillRunning = true
            dTask.cancel()
            if case .success(let a) = await dTask.value { a.0.cancel() }
        }
        if let v = vTask, vResult == nil {
            v.cancel()
            if case .success(let a) = await v.value { a.0.cancel() }
        }

        switch dResult {
        case .success: result.direct = .ok
        case .failure(let e): result.direct = .hardFailure(e)
        case nil: result.direct = directStillRunning && result.winner == .vpn ? .stalled : .notFinished
        }
        if case .failure(let e) = vResult { result.vpnError = e }
        result.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        return result
    }
}
