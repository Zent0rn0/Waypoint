import Foundation
import Network

// MARK: - Listener

/// Loopback-only mixed-protocol listener: SOCKS5, HTTP CONNECT, absolute-form HTTP and the PAC file share one port.
final class ProxyServer: @unchecked Sendable {
    private let engine: Engine
    private var listener: NWListener?

    init(engine: Engine) { self.engine = engine }

    func start(port: UInt16) async throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw UpstreamError("bad listen port") }
        let params = NWParameters.tcp
        // Bind to 127.0.0.1 explicitly. (`requiredInterfaceType = .loopback` alone still yields a *:port
        // wildcard listener — i.e. an open proxy for the whole LAN.)
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [engine] conn in
            Task.detached { await ClientSession(conn: conn, engine: engine).run() }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { cont.resume() }
                case .failed(let e): if once.claim() { cont.resume(throwing: e) }
                case .cancelled: if once.claim() { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            l.start(queue: DispatchQueue(label: "waypoint.listener", qos: .userInitiated))
        }
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }
}

// MARK: - One client connection

private enum Framing {
    case socks5, httpConnect, httpPlain

    var ack: Data {
        switch self {
        case .socks5: return Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        case .httpConnect: return Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        case .httpPlain: return Data()
        }
    }

    func failure(blocked: Bool) -> Data {
        switch self {
        case .socks5: return Data([5, blocked ? 2 : 5, 0, 1, 0, 0, 0, 0, 0, 0])
        case .httpConnect, .httpPlain:
            return Data("HTTP/1.1 \(blocked ? "403 Forbidden" : "502 Bad Gateway")\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
        }
    }
}

final class ClientSession {
    private let conn: NWConnection
    private let engine: Engine
    private var reader: BufferedReader!

    init(conn: NWConnection, engine: Engine) {
        self.conn = conn
        self.engine = engine
    }

    func run() async {
        defer { conn.cancel() }
        do {
            try await conn.awaitReady()
            reader = BufferedReader(conn)
            let first = try await reader.peek(1)
            if first[first.startIndex] == 0x05 { try await handleSOCKS5() } else { try await handleHTTP() }
        } catch {
            // Client went away or spoke garbage; nothing to report.
        }
    }

    // MARK: SOCKS5 (CONNECT only)

    private func handleSOCKS5() async throws {
        let greeting = try await reader.readExactly(2)
        _ = try await reader.readExactly(Int(greeting[greeting.startIndex + 1]))
        try await conn.sendAsync(Data([5, 0]))                                   // no authentication

        let h = try await reader.readExactly(4)
        let cmd = h[h.startIndex + 1], atyp = h[h.startIndex + 3]
        let host: String
        switch atyp {
        case 1:
            let a = try await reader.readExactly(4)
            host = a.map { String($0) }.joined(separator: ".")
        case 3:
            let l = try await reader.readExactly(1)
            let name = try await reader.readExactly(Int(l[l.startIndex]))
            host = String(decoding: name, as: UTF8.self)
        case 4:
            let a = try await reader.readExactly(16)
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: a) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
            host = String(cString: buf)
        default:
            try await conn.sendAsync(Data([5, 8, 0, 1, 0, 0, 0, 0, 0, 0]))
            return
        }
        let pb = try await reader.readExactly(2)
        let port = UInt16(pb[pb.startIndex]) << 8 | UInt16(pb[pb.startIndex + 1])
        guard cmd == 1 else {
            try await conn.sendAsync(Data([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]))       // command not supported
            return
        }
        try await tunnel(host: host, port: port, framing: .socks5, preloaded: Data())
    }

    // MARK: HTTP proxy + PAC

    private func handleHTTP() async throws {
        let head = try await reader.readUntil(Data("\r\n\r\n".utf8), max: 32 * 1024)
        let text = String(decoding: head, as: UTF8.self)
        let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 3 else { try await respond(400, "Bad Request"); return }
        let method = parts[0], target = parts[1]

        if method == "CONNECT" {
            guard let (host, port) = Self.splitHostPort(target, defaultPort: 443) else { try await respond(400, "Bad Request"); return }
            try await tunnel(host: host, port: port, framing: .httpConnect, preloaded: reader.takeBuffered())
        } else if target.hasPrefix("/") {
            if target.hasPrefix("/proxy.pac") {
                let body = PAC.script(port: engine.settings.listenPort)
                try await respond(200, "OK", contentType: "application/x-ns-proxy-autoconfig", body: body)
            } else {
                try await respond(404, "Not Found")
            }
        } else if let url = URL(string: target), let host = url.host {
            // Plain HTTP through an HTTP proxy: origins must accept the absolute-form request line (RFC 7230 §5.3.2),
            // so the request is forwarded verbatim. Multiple hosts on one keep-alive connection are not supported.
            try await tunnel(host: host, port: UInt16(url.port ?? 80), framing: .httpPlain, preloaded: head + reader.takeBuffered())
        } else {
            try await respond(400, "Bad Request")
        }
    }

    private func respond(_ code: Int, _ reason: String, contentType: String = "text/plain", body: String = "") async throws {
        let payload = Data(body.utf8)
        var r = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        r += body
        try await conn.sendAsync(Data(r.utf8))
    }

    static func splitHostPort(_ s: String, defaultPort: UInt16) -> (String, UInt16)? {
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") {                    // [v6]:port
            let host = String(s[s.index(after: s.startIndex)..<end])
            let rest = s[s.index(after: end)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        if p.count == 2, let port = UInt16(p[1]) { return (String(p[0]), port) }
        return p.count == 1 ? (s, defaultPort) : nil
    }

    // MARK: routing

    private func tunnel(host rawHost: String, port: UInt16, framing: Framing, preloaded: Data) async throws {
        let host = normalizeHost(rawHost)
        let started = Date()
        engine.connectionOpened()
        defer { engine.connectionClosed() }

        let decision = engine.rules.decide(host: host, port: port)
        if decision.action == .block {
            try? await conn.sendAsync(framing.failure(blocked: true))
            engine.emit(host: host, port: port, route: "block", source: decision.source.rawValue, started: started)
            return
        }
        if decision.source == .learned || decision.source == .starter { engine.revalidateIfNeeded(host: host) }

        if decision.action == .race {
            try await raceFlow(host: host, port: port, framing: framing, preloaded: preloaded, started: started)
        } else {
            try await knownFlow(host: host, port: port, decision: decision, framing: framing, preloaded: preloaded, started: started)
        }
    }

    /// The verdict is already known: connect on that path (falling back to the other if it cannot even connect).
    private func knownFlow(host: String, port: UInt16, decision: Decision, framing: Framing, preloaded: Data, started: Date) async throws {
        var path: PathKind = decision.action == .vpn ? .vpn : .direct
        var note = ""
        var remote: NWConnection?
        do {
            remote = try await engine.dial(path, host: host, port: port)
        } catch {
            note = "\(path.rawValue) не подключился: \(Self.short(error))"
            if decision.allowFallback {
                let alt: PathKind = path == .vpn ? .direct : .vpn
                if let c = try? await engine.dial(alt, host: host, port: port) {
                    remote = c; path = alt; note += " → \(alt.rawValue)"
                }
            }
        }
        guard let remote else {
            try? await conn.sendAsync(framing.failure(blocked: false))
            engine.emit(host: host, port: port, route: "failed", source: decision.source.rawValue, note: note, started: started)
            return
        }
        try await conn.sendAsync(framing.ack)
        engine.emit(host: host, port: port, route: path.rawValue, source: decision.source.rawValue, note: note, started: started)
        await relay(remote: remote, path: path, clientFirst: preloaded + reader.takeBuffered())
    }

    /// Unknown host on a web port: tell the client "connected" right away, buffer its first flight,
    /// race the two paths, replay the flight on the winner.
    private func raceFlow(host: String, port: UInt16, framing: Framing, preloaded: Data, started: Date) async throws {
        try await conn.sendAsync(framing.ack)
        if !preloaded.isEmpty { reader.unread(preloaded) }          // uniform: everything the client sent lives in the reader
        let flight = try await readFirstFlight(port: port)

        if !flight.raceable {
            try await sequentialFlow(host: host, port: port, first: flight.data, started: started)
            return
        }

        // Tunnel mode hands us bare IPs: recover the real name from the traffic so verdicts, learning and the log use it.
        let name: String = isIPLiteral(host) ? (Sniff.tlsServerName(flight.data) ?? Sniff.httpHost(flight.data) ?? host) : host
        if name != host {
            let known = engine.rules.decide(host: name, port: port)
            if known.action == .block { engine.emit(host: name, port: port, route: "block", source: known.source.rawValue, started: started); return }
            if known.action == .vpn || known.action == .direct {
                try await committedFlow(dialHost: known.action == .vpn ? name : host, path: known.action == .vpn ? .vpn : .direct,
                                        name: name, port: port, source: known.source.rawValue, first: flight.data, started: started)
                return
            }
        }
        let result = await engine.racer.run(host: host, port: port, initial: flight.data)
        guard let winner = result.winner, let remote = result.connection else {
            engine.emit(host: name, port: port, route: "failed", source: "race",
                        note: "недоступен на обоих путях", started: started)
            return
        }

        var note = "гонка: \(winner.rawValue) за \(result.elapsedMs) мс"
        var learnCandidate = false
        switch (winner, result.direct) {
        case (.direct, _):
            engine.rules.noteDirectOK(host: name)
            engine.noteDirectLatency(ms: result.elapsedMs)
        case (.vpn, .hardFailure(let e)):
            note += "; напрямую: \(Self.short(e))"
            learnCandidate = true
        case (.vpn, .stalled):
            note += "; напрямую: молчит"
            // On TLS ports a silent direct path after the TCP handshake is the classic SNI-blackhole signature.
            learnCandidate = FirstResponse.isTLSPort(port)
        default: break
        }
        engine.emit(host: name, port: port, route: winner.rawValue, source: "race", note: note, started: started)
        if learnCandidate {
            // Off the hot path: the client must not wait for the second opinion.
            let eng = engine, host = name, p = port, t0 = started
            Task.detached {
                guard await eng.confirmBlocked(host: host, port: p) else { return }
                if eng.rules.noteDirectBlocked(host: host) { eng.emit(host: host, port: p, route: "vpn", source: "race", note: "выучено → VPN (подтверждено повторной проверкой)", started: t0) }
            }
        }

        do { try await conn.sendAsync(result.firstBytes) } catch { remote.cancel(); throw error }
        engine.addBytes(result.firstBytes.count, path: winner)
        // Bytes the client sent right behind its first flight were buffered by the reader; they belong to the winner only.
        await relay(remote: remote, path: winner, clientFirst: reader.takeBuffered())
    }

    /// Requests that cannot be replayed safely (chunked / huge bodies, Expect: 100-continue):
    /// direct if it connects, otherwise VPN. No verdict is learned from these.
    private func sequentialFlow(host: String, port: UInt16, first: Data, started: Date) async throws {
        var path: PathKind = .direct
        var remote = try? await engine.dial(.direct, host: host, port: port)
        if remote == nil { remote = try? await engine.dial(.vpn, host: host, port: port); path = .vpn }
        guard let remote else {
            engine.emit(host: host, port: port, route: "failed", source: "race", note: "не подключился", started: started)
            return
        }
        engine.emit(host: host, port: port, route: path.rawValue, source: "race", note: "запрос с телом — без гонки", started: started)
        do { try await remote.sendAsync(first) } catch { remote.cancel(); throw error }
        engine.addBytes(first.count, path: path)
        await relay(remote: remote, path: path, clientFirst: reader.takeBuffered())
    }

    /// Verdict already known once the name was recovered: connect on that path only and replay the first flight there.
    private func committedFlow(dialHost: String, path: PathKind, name: String, port: UInt16, source: String, first: Data, started: Date) async throws {
        guard let remote = try? await engine.dial(path, host: dialHost, port: port) else {
            engine.emit(host: name, port: port, route: "failed", source: source, note: "\(path.rawValue) не подключился", started: started)
            return
        }
        engine.emit(host: name, port: port, route: path.rawValue, source: source, note: "имя из трафика", started: started)
        do { try await remote.sendAsync(first) } catch { remote.cancel(); throw error }
        engine.addBytes(first.count, path: path)
        await relay(remote: remote, path: path, clientFirst: reader.takeBuffered())
    }

    private struct FirstFlight { var data: Data; var raceable: Bool }

    /// Reads exactly the client's first flight: one whole TLS record, or the HTTP request head plus (if small) its body.
    private func readFirstFlight(port: UInt16) async throws -> FirstFlight {
        if FirstResponse.isTLSPort(port) {
            let head = try await reader.peek(5)
            let b = [UInt8](head)
            if b[0] == 0x16 && b[1] == 0x03 {
                let total = 5 + (Int(b[3]) << 8 | Int(b[4]))
                if total <= 16 * 1024 + 5 { return FirstFlight(data: try await reader.readExactly(total), raceable: true) }
            }
            return FirstFlight(data: try await reader.readSome(), raceable: false)      // not TLS: cannot validate a reply
        }
        // Port 80 is not always HTTP (Telegram MTProto): unless the flight starts like an HTTP request, do not race.
        let lead = String(decoding: try await reader.peek(4), as: UTF8.self)
        guard ["GET ", "POST", "HEAD", "PUT ", "DELE", "OPTI", "PATC", "CONN", "TRAC"].contains(lead) else {
            return FirstFlight(data: try await reader.readSome(), raceable: false)
        }
        guard let head = try? await reader.readUntil(Data("\r\n\r\n".utf8), max: 32 * 1024) else {
            return FirstFlight(data: try await reader.readSome(), raceable: false)
        }
        switch HTTPBodyPlan.parse(head: head) {
        case .none: return FirstFlight(data: head, raceable: true)
        case .fixed(let n): return FirstFlight(data: head + (try await reader.readExactly(n)), raceable: true)
        case .unsuitable: return FirstFlight(data: head, raceable: false)
        }
    }

    // MARK: relay

    private func relay(remote: NWConnection, path: PathKind, clientFirst: Data) async {
        if path == .vpn { engine.vpnBegin() }
        defer {
            remote.cancel()
            if path == .vpn { engine.vpnEnd() }
        }
        let client = conn, eng = engine
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(from: client, to: remote, first: clientFirst, path: path, engine: eng) }
            group.addTask { await Self.pump(from: remote, to: client, first: Data(), path: path, engine: eng) }
        }
    }

    private static func pump(from: NWConnection, to: NWConnection, first: Data, path: PathKind, engine: Engine) async {
        do {
            if !first.isEmpty { try await to.sendAsync(first); engine.addBytes(first.count, path: path) }
            while true {
                let (d, eof) = try await from.receiveAsync()
                if eof { await to.sendFIN(); return }          // half-close: the other direction may still be flowing
                if !d.isEmpty { try await to.sendAsync(d); engine.addBytes(d.count, path: path) }
            }
        } catch {
            from.cancel()
            to.cancel()
        }
    }

    static func short(_ e: Error) -> String {
        if e is TimeoutError { return "таймаут" }
        if let b = e as? BadFirstResponse { return b.reason }
        if e is EOFError { return "соединение сброшено" }
        if let n = e as? NWError {
            switch n {
            case .posix(let c): return c == .ECONNRESET ? "RST" : c == .ETIMEDOUT ? "таймаут" : c == .ECONNREFUSED ? "отказ" : "\(c)"
            case .dns: return "DNS"
            case .tls: return "TLS"
            default: return "\(n)"
            }
        }
        return "\(e)"
    }
}
