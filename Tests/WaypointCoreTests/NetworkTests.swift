import Testing
import Foundation
import Network
@testable import WaypointCore

// MARK: - Loopback actors

/// A loopback TCP server whose behaviour stands in for "the direct path" or "the VPN path".
final class TestServer: @unchecked Sendable {
    enum Behavior {
        case reply(Data, delayMs: Int)   // after the first bytes arrive, answer with this
        case silent                      // black hole (SNI-DPI drop / IP blackhole)
        case reset                       // closes immediately (RST/FIN)
        case echo
    }
    static let tls = Data([0x16, 0x03, 0x03, 0x00, 0x05, 1, 2, 3, 4, 5])

    private let listener: NWListener
    private let lock = NSLock()
    private var conns: [NWConnection] = []
    private(set) var received = Data()
    private(set) var closed = 0
    private(set) var accepted = 0
    private(set) var port: UInt16 = 0

    init(_ behavior: Behavior) async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let l = listener
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            l.stateUpdateHandler = { st in
                if case .ready = st, once.claim() { c.resume() }
                if case .failed(let e) = st, once.claim() { c.resume(throwing: e) }
            }
            l.newConnectionHandler = { [unowned self] conn in self.accept(conn, behavior) }
            l.start(queue: .global())
        }
        port = listener.port!.rawValue
    }

    private func accept(_ conn: NWConnection, _ behavior: Behavior) {
        lock.lock(); conns.append(conn); accepted += 1; lock.unlock()
        conn.start(queue: .global())
        if case .reset = behavior { conn.cancel(); lock.lock(); closed += 1; lock.unlock(); return }
        func loop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, err in
                if let data, !data.isEmpty {
                    lock.lock(); received.append(data); lock.unlock()
                    switch behavior {
                    case .reply(let d, let delay):
                        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay)) { conn.send(content: d, completion: .idempotent) }
                    case .echo: conn.send(content: data, completion: .idempotent)
                    default: break
                    }
                }
                if err != nil || isComplete { lock.lock(); closed += 1; lock.unlock(); return }
                loop()
            }
        }
        loop()
    }

    func stop() { listener.cancel(); lock.lock(); conns.forEach { $0.cancel() }; lock.unlock() }
}

struct LoopbackDialer: PathDialer {
    private(set) var port: UInt16 = 0
    func dial(host: String, port _: UInt16, deadlineMs: Int) async throws -> NWConnection {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        do { try await c.awaitReady() } catch { c.cancel(); throw error }
        return c
    }
}

func waitUntil(timeout: Double = 2, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
    return cond()
}

// MARK: - Race

@Suite("Race", .serialized) struct RaceTests {
    let hello = Data([0x16, 0x03, 0x01, 0x00, 0x03, 9, 9, 9])          // pretend ClientHello

    func run(direct: TestServer.Behavior, vpn: TestServer.Behavior, hedge: Int = 150, deadline: Int = 3000)
        async throws -> (RaceResult, TestServer, TestServer) {
        let d = try await TestServer(direct), v = try await TestServer(vpn)
        let racer = Racer(direct: LoopbackDialer(port: d.port), vpn: LoopbackDialer(port: v.port),
                          config: RaceConfig(hedgeMs: hedge, directDeadlineMs: deadline, vpnDeadlineMs: deadline))
        let r = await racer.run(host: "example.test", port: 443, initial: hello)
        r.connection?.cancel()
        return (r, d, v)
    }

    @Test func fastDirectWinsAndVPNIsNeverTouched() async throws {
        let (r, d, v) = try await run(direct: .reply(TestServer.tls, delayMs: 0), vpn: .reply(TestServer.tls, delayMs: 0), hedge: 500)
        defer { d.stop(); v.stop() }
        #expect(r.winner == .direct)
        #expect(r.firstBytes == TestServer.tls)
        #expect(d.received == hello)                                    // the flight was delivered intact
        #expect(v.accepted == 0)                                        // no quota spent when direct is healthy
    }

    @Test func silentDirectLosesToVPNAfterTheHedgeAndFlightIsReplayedIntact() async throws {
        let (r, d, v) = try await run(direct: .silent, vpn: .reply(TestServer.tls, delayMs: 0), hedge: 200)
        defer { d.stop(); v.stop() }
        #expect(r.winner == .vpn)
        #expect(r.elapsedMs >= 190)
        if case .stalled = r.direct {} else { Issue.record("direct should be reported as stalled, got \(r.direct)") }
        #expect(v.received == hello)                                    // replayed byte-for-byte
        #expect(await waitUntil { d.closed == 1 }, "the losing direct connection must be closed, not leaked")
    }

    @Test func resetDirectFailsOverImmediatelyWithoutWaitingForTheHedge() async throws {
        let (r, d, v) = try await run(direct: .reset, vpn: .reply(TestServer.tls, delayMs: 0), hedge: 5000)
        defer { d.stop(); v.stop() }
        #expect(r.winner == .vpn)
        #expect(r.elapsedMs < 1500)
        if case .hardFailure = r.direct {} else { Issue.record("expected hard failure, got \(r.direct)") }
    }

    @Test func blockPageGarbageOnTLSPortCountsAsFailure() async throws {
        let (r, d, v) = try await run(direct: .reply(Data("HTTP/1.1 403 Forbidden\r\n\r\nblocked".utf8), delayMs: 0),
                                      vpn: .reply(TestServer.tls, delayMs: 0), hedge: 5000)
        defer { d.stop(); v.stop() }
        #expect(r.winner == .vpn)
        if case .hardFailure(let e) = r.direct { #expect(e is BadFirstResponse) } else { Issue.record("expected hardFailure") }
    }

    @Test func slowButHealthyDirectStillWinsIfVPNIsSlower() async throws {
        let (r, d, v) = try await run(direct: .reply(TestServer.tls, delayMs: 300), vpn: .reply(TestServer.tls, delayMs: 800), hedge: 100)
        defer { d.stop(); v.stop() }
        #expect(r.winner == .direct)
        #expect(await waitUntil { v.closed == 1 }, "the VPN attempt that was started by the hedge must be closed")
    }

    @Test func vpnStartedByHedgeCanOvertakeASlowDirect() async throws {
        let (r, d, v) = try await run(direct: .reply(TestServer.tls, delayMs: 1200), vpn: .reply(TestServer.tls, delayMs: 0), hedge: 100)
        defer { d.stop(); v.stop() }
        #expect(r.winner == .vpn)
        #expect(r.elapsedMs < 900)
    }

    @Test func bothDeadMeansNoWinner() async throws {
        let (r, d, v) = try await run(direct: .silent, vpn: .silent, hedge: 50, deadline: 400)
        defer { d.stop(); v.stop() }
        #expect(r.winner == nil && r.connection == nil)
        #expect(await waitUntil { d.closed == 1 && v.closed == 1 })
    }
}

// MARK: - Whole proxy over loopback (SOCKS5, HTTP CONNECT, PAC, block)

@Suite("Proxy end-to-end", .serialized) struct ProxyTests {
    func startEngine() async throws -> Engine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wp-e2e-\(UUID().uuidString)")
        var s = AppSettings(); s.listenPort = UInt16.random(in: 41000...49000); s.region = .none
        let e = Engine(settings: s, supportDirectory: dir)
        try await e.start()
        return e
    }

    func connect(_ e: Engine) async throws -> NWConnection {
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: e.settings.listenPort)!, using: .tcp)
        try await c.awaitReady(); return c
    }

    func read(_ c: NWConnection, atLeast n: Int) async throws -> Data {
        var buf = Data()
        while buf.count < n { let (d, eof) = try await withTimeout(ms: 3000) { try await c.receiveAsync() }; if eof { break }; buf += d }
        return buf
    }

    @Test func socks5ConnectRelaysBothWays() async throws {
        let e = try await startEngine(); defer { e.stop() }
        let origin = try await TestServer(.echo); defer { origin.stop() }
        let c = try await connect(e); defer { c.cancel() }
        try await c.sendAsync(Data([5, 1, 0]))
        #expect(try await read(c, atLeast: 2) == Data([5, 0]))
        try await c.sendAsync(Socks5.connectRequest(host: "127.0.0.1", port: origin.port))
        let reply = try await read(c, atLeast: 10)
        #expect(reply.prefix(2) == Data([5, 0]))
        try await c.sendAsync(Data("hello through waypoint".utf8))
        #expect(String(decoding: try await read(c, atLeast: 22), as: UTF8.self) == "hello through waypoint")
        #expect(e.recentEvents.last?.route == "direct")
        #expect(e.recentEvents.last?.source == "local")
    }

    @Test func httpConnectWorksToo() async throws {
        let e = try await startEngine(); defer { e.stop() }
        let origin = try await TestServer(.echo); defer { origin.stop() }
        let c = try await connect(e); defer { c.cancel() }
        try await c.sendAsync(Data("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        #expect(String(decoding: try await read(c, atLeast: 39), as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        try await c.sendAsync(Data("ping".utf8))
        #expect(String(decoding: try await read(c, atLeast: 4), as: UTF8.self) == "ping")
    }

    @Test func pacIsServedOnTheSamePort() async throws {
        let e = try await startEngine(); defer { e.stop() }
        let c = try await connect(e); defer { c.cancel() }
        try await c.sendAsync(Data("GET /proxy.pac HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        var all = Data()
        while true { let (d, eof) = try await withTimeout(ms: 3000) { try await c.receiveAsync() }; if eof { break }; all += d; if String(decoding: all, as: UTF8.self).contains("FindProxyForURL") && all.count > 400 { break } }
        let text = String(decoding: all, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200"))
        #expect(text.contains("application/x-ns-proxy-autoconfig"))
        #expect(text.contains("127.0.0.1:\(e.settings.listenPort)"))
    }

    @Test func blockedHostIsRefused() async throws {
        let e = try await startEngine(); defer { e.stop() }
        e.rules.setManualRules([.init(route: .block, kind: .suffix, value: "ads.example")], persist: false)
        let c = try await connect(e); defer { c.cancel() }
        try await c.sendAsync(Data([5, 1, 0])); _ = try await read(c, atLeast: 2)
        try await c.sendAsync(Socks5.connectRequest(host: "tracker.ads.example", port: 443))
        let r = try await read(c, atLeast: 10)
        #expect(r[1] == 2)                                               // "connection not allowed by ruleset"
        #expect(e.recentEvents.last?.route == "block")
    }

    @Test func nonConnectSocksCommandIsRejected() async throws {
        let e = try await startEngine(); defer { e.stop() }
        let c = try await connect(e); defer { c.cancel() }
        try await c.sendAsync(Data([5, 1, 0])); _ = try await read(c, atLeast: 2)
        try await c.sendAsync(Data([5, 3, 0, 1, 1, 2, 3, 4, 0, 53]))     // UDP ASSOCIATE
        #expect(try await read(c, atLeast: 10)[1] == 7)
    }

    @Test func listenerIsLoopbackOnly() async throws {
        let e = try await startEngine(); defer { e.stop() }
        let r = runProcess("/usr/sbin/lsof", ["-nP", "-iTCP:\(e.settings.listenPort)", "-sTCP:LISTEN"])
        #expect(r.out.contains("127.0.0.1:\(e.settings.listenPort)"), "listener must be bound to 127.0.0.1, got:\n\(r.out)")
        #expect(!r.out.contains("*:\(e.settings.listenPort)"))
    }
}
