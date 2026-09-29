import Testing
import Foundation
@testable import WaypointCore

@Suite("Domains") struct DomainTests {
    @Test func normalisation() {
        #expect(normalizeHost("WWW.Example.COM.") == "www.example.com")
        #expect(normalizeHost("[::1]") == "::1")
    }

    @Test func localHosts() {
        for h in ["localhost", "printer", "nas.local", "192.168.31.1", "10.1.2.3", "172.20.0.5", "127.0.0.1", "169.254.1.1", "100.100.1.1", "::1", "fe80::1", "fd12::1"] {
            #expect(isLocalHost(h), "\(h) should be local")
        }
        for h in ["example.com", "8.8.8.8", "172.32.0.1", "100.63.0.1", "2001:db8::1"] {
            #expect(!isLocalHost(h), "\(h) should not be local")
        }
    }

    @Test func registrable() {
        #expect(registrableDomain("a.b.youtube.com") == "youtube.com")
        #expect(registrableDomain("youtube.com") == "youtube.com")
        #expect(registrableDomain("www.bbc.co.uk") == "bbc.co.uk")
        #expect(registrableDomain("someone.github.io") == "someone.github.io")
        #expect(registrableDomain("x.someone.github.io") == "someone.github.io")
        #expect(registrableDomain("149.154.167.51") == "149.154.167.0/24")
        #expect(registrableDomain("localhost") == "localhost")
    }

    @Test func domainSet() {
        let s = DomainSet(suffixes: ["youtube.com", "ru"], exact: ["api.exact.io"], keywords: ["tiktok"])
        #expect(s.matches("youtube.com"))
        #expect(s.matches("m.youtube.com"))
        #expect(!s.matches("notyoutube.com"))          // suffix match is label-aware
        #expect(s.matches("yandex.ru"))
        #expect(s.matches("API.exact.io"))
        #expect(!s.matches("x.api.exact.io"))
        #expect(s.matches("cdn.tiktokcdn.com"))
        #expect(!s.matches("example.org"))
    }

    @Test func cidr() {
        let c = IPv4CIDR("149.154.160.0/20")!
        #expect(c.contains(ipv4Value("149.154.167.50")!))
        #expect(!c.contains(ipv4Value("149.154.176.1")!))
        #expect(IPv4CIDR("1.2.3.4")!.contains(ipv4Value("1.2.3.4")!))
        #expect(IPv4CIDR("1.2.3.4/33") == nil)
    }
}

@Suite("Rules") struct RuleTests {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000) }

    func engine(region: Region = .russia, clock: Clock = Clock(), dir: URL? = nil) -> RuleEngine {
        RuleEngine(directory: dir, region: region, now: { clock.t })
    }

    @Test func parsing() {
        #expect(ManualRule.parse("vpn youtube.com") == .init(route: .vpn, kind: .suffix, value: "youtube.com"))
        #expect(ManualRule.parse("vpn *.youtube.com") == .init(route: .vpn, kind: .suffix, value: "youtube.com"))
        #expect(ManualRule.parse("direct full:api.bank.ru # comment") == .init(route: .direct, kind: .exact, value: "api.bank.ru"))
        #expect(ManualRule.parse("vpn keyword:tiktok")?.kind == .keyword)
        #expect(ManualRule.parse("direct cidr:10.0.0.0/8")?.kind == .cidr)
        #expect(ManualRule.parse("vpn 1.2.3.4")?.kind == .exact)
        #expect(ManualRule.parse("# just a comment") == nil)
        #expect(ManualRule.parse("maybe example.com") == nil)
        #expect(ManualRule.parse("vpn cidr:nonsense") == nil)
        let rules = ManualRule.parseAll("vpn a.com\n\n# x\ndirect b.com\n")
        #expect(ManualRule.parseAll(ManualRule.serialize(rules)) == rules)
    }

    @Test func precedence() {
        let e = engine()
        // starter: youtube → vpn, .ru → direct
        #expect(e.decide(host: "www.youtube.com", port: 443) == Decision(.vpn, .starter, allowFallback: true))
        #expect(e.decide(host: "sberbank.ru", port: 443).action == .direct)
        // manual beats starter
        e.setManualRules([.init(route: .direct, kind: .suffix, value: "youtube.com")], persist: false)
        #expect(e.decide(host: "www.youtube.com", port: 443) == Decision(.direct, .manual))
        // most specific manual match wins
        e.setManualRules([.init(route: .vpn, kind: .suffix, value: "example.com"),
                          .init(route: .direct, kind: .suffix, value: "bank.example.com"),
                          .init(route: .block, kind: .exact, value: "ads.example.com")], persist: false)
        #expect(e.decide(host: "x.example.com", port: 443).action == .vpn)
        #expect(e.decide(host: "a.bank.example.com", port: 443).action == .direct)
        #expect(e.decide(host: "ads.example.com", port: 443).action == .block)
    }

    @Test func unknownHostsRaceOnWebPortsOnly() {
        let e = engine(region: .none)
        #expect(e.decide(host: "unknown.example", port: 443).action == .race)
        #expect(e.decide(host: "unknown.example", port: 80).action == .race)
        #expect(e.decide(host: "unknown.example", port: 22).action == .direct)     // not raceable: server-first protocols
        #expect(e.decide(host: "unknown.example", port: 22).allowFallback)
        #expect(e.decide(host: "192.168.1.5", port: 443) == Decision(.direct, .local))
    }

    @Test func learningNeedsTwoFailuresAndForgetsOldOnes() {
        let clock = Clock()
        let e = engine(region: .none, clock: clock)
        #expect(e.noteDirectBlocked(host: "blocked.example") == false)
        #expect(e.decide(host: "blocked.example", port: 443).action == .race)     // one failure is not enough
        clock.t.addTimeInterval(200)                                               // outside the 120 s window
        #expect(e.noteDirectBlocked(host: "blocked.example") == false)
        #expect(e.noteDirectBlocked(host: "cdn.blocked.example") == true)          // same registrable domain
        #expect(e.decide(host: "www.blocked.example", port: 443) == Decision(.vpn, .learned, allowFallback: true))
        // expires if never confirmed
        clock.t.addTimeInterval(31 * 24 * 3600)
        #expect(e.decide(host: "www.blocked.example", port: 443).action == .race)
    }

    @Test func directSuccessClearsSuspicion() {
        let e = engine(region: .none)
        e.noteDirectBlocked(host: "flaky.example")
        e.noteDirectOK(host: "flaky.example")
        #expect(e.noteDirectBlocked(host: "flaky.example") == false)               // counter restarted
        #expect(e.decide(host: "flaky.example", port: 443).source == .unknown)
    }

    @Test func recentDirectOKSkipsTheRace() {
        let e = engine(region: .none)
        e.noteDirectOK(host: "fine.example")
        #expect(e.decide(host: "fine.example", port: 443) == Decision(.direct, .learned, allowFallback: true))
    }

    @Test func persistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = engine(region: .none, dir: dir)
        a.noteDirectBlocked(host: "p.example"); a.noteDirectBlocked(host: "p.example")
        a.setManualRules([.init(route: .vpn, kind: .suffix, value: "manual.example")])
        let b = engine(region: .none, dir: dir)
        #expect(b.learnedEntries.map(\.domain) == ["p.example"])
        #expect(b.manual.map(\.value) == ["manual.example"])
        #expect(b.decide(host: "p.example", port: 443).source == .learned)
    }

    @Test func pinningReplacesAndForgets() {
        let e = engine(region: .none)
        e.noteDirectBlocked(host: "x.example"); e.noteDirectBlocked(host: "x.example")
        e.pin(host: "www.x.example", route: .direct)
        #expect(e.learnedEntries.isEmpty)
        #expect(e.decide(host: "a.x.example", port: 443) == Decision(.direct, .manual))
        e.pin(host: "www.x.example", route: nil)                                   // back to automatic
        #expect(e.decide(host: "a.x.example", port: 443).source == .unknown)
    }

    @Test func revalidationIsDueOnlyForStaleLearnedEntries() {
        let clock = Clock()
        let e = engine(region: .none, clock: clock)
        e.noteDirectBlocked(host: "r.example"); e.noteDirectBlocked(host: "r.example")
        #expect(!e.needsRevalidation(host: "r.example"))
        clock.t.addTimeInterval(7 * 3600)
        #expect(e.needsRevalidation(host: "r.example"))
        e.markConfirmed(host: "r.example")
        #expect(!e.needsRevalidation(host: "r.example"))
    }

    @Test func telegramRangesGoThroughVPNByAddress() {
        let e = RuleEngine(directory: nil, region: .russia)
        #expect(e.decide(host: "149.154.167.35", port: 80) == Decision(.vpn, .starter, allowFallback: true))
        #expect(e.decide(host: "91.108.56.106", port: 443).action == .vpn)
        #expect(e.decide(host: "149.154.176.1", port: 443).action != .vpn)           // just outside 149.154.160.0/20
        #expect(RuleEngine(directory: nil, region: .none).decide(host: "149.154.167.35", port: 80).action == .race)
    }
}
