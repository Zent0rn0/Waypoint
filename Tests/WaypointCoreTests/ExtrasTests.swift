import Testing
import Foundation
import Network
@testable import WaypointCore

@Suite("Live connections & traffic") struct LiveTests {
    func conn(_ id: String, _ chain: [String], up: UInt64, down: UInt64, path: String? = "/Applications/Discord.app/Contents/Frameworks/Discord Helper.app/Contents/MacOS/Discord Helper") -> LiveConnection {
        LiveConnection(id: id, host: "h.example", port: 443, network: "tcp", processPath: path, chain: chain, rule: "", upload: up, download: down, start: Date())
    }

    @Test func pathClassification() {
        #expect(conn("1", ["direct-phys"], up: 0, down: 0).path == .direct)
        #expect(conn("2", ["via-happ", "pool-video"], up: 0, down: 0).path == .vpn)
        #expect(conn("3", ["srv-2", "pool-general"], up: 0, down: 0).path == .vpn)
        #expect(conn("3b", ["srv-2", "pool-general"], up: 0, down: 0).carrier == "srv-2")
        #expect(conn("4", ["waypoint-race"], up: 0, down: 0).path == .race)
        #expect(conn("5", ["REJECT"], up: 0, down: 0).path == .blocked)
    }

    @Test func raceOutcomeRelabelsOnlyRaceFlows() {
        let race = conn("r", ["waypoint-race"], up: 1, down: 2)
        #expect(race.resolving(raceOutcome: "vpn").path == .vpn)
        #expect(race.resolving(raceOutcome: "direct").path == .direct)
        #expect(race.resolving(raceOutcome: nil).path == .race)
        #expect(conn("d", ["direct-phys"], up: 1, down: 2).resolving(raceOutcome: "vpn").path == .direct)      // decided elsewhere: untouched
    }

    @Test func helperProcessesRollUpToTheirApp() {
        let c = conn("1", ["direct-phys"], up: 0, down: 0)
        #expect(c.appPath == "/Applications/Discord.app" && c.appName == "Discord")
        #expect(conn("2", [], up: 0, down: 0, path: "/usr/bin/curl").appName == "curl")
        #expect(conn("3", [], up: 0, down: 0, path: nil).appName == "система")
    }

    @Test func trackerAttributesOnlyGrowthPerAppAndPath() {
        let t = TrafficTracker(); let t0 = Date()
        let disc = "/Applications/Discord.app/Contents/MacOS/Discord"
        t.ingest(.init(connections: [conn("a", ["via-happ"], up: 100, down: 900, path: disc), conn("b", ["direct-phys"], up: 10, down: 90, path: "/usr/bin/curl")], uploadTotal: 110, downloadTotal: 990), at: t0)
        var s = t.ingest(.init(connections: [conn("a", ["via-happ"], up: 150, down: 1900, path: disc), conn("b", ["direct-phys"], up: 10, down: 90, path: "/usr/bin/curl")], uploadTotal: 160, downloadTotal: 1990), at: t0.addingTimeInterval(1))
        // first snapshot: 1000 B via VPN + 100 B direct; second adds only the growth: 50 up + 1000 down
        #expect(s.byApp["/Applications/Discord.app"]?.vpn == 2050)
        #expect(s.byApp["/usr/bin/curl"]?.direct == 100)                       // counted once, not twice
        #expect(s.total.vpn == 2050 && s.total.direct == 100)
        #expect(abs(s.downRate - 1000) < 1 && abs(s.upRate - 50) < 1)
        // a closed connection disappears without being double counted; a new one with the same id starts from zero
        s = t.ingest(.init(connections: [conn("a", ["via-happ"], up: 5, down: 5, path: disc)], uploadTotal: 165, downloadTotal: 1995), at: t0.addingTimeInterval(2))
        #expect(s.total.vpn == 2050 + 10)
    }

    @Test func apiClientParsesRealShapedReplies() async throws {
        let json = """
        {"downloadTotal":1000,"uploadTotal":500,"memory":0,"connections":[
          {"id":"abc","metadata":{"network":"tcp","type":"tun/tun-in","sourceIP":"172.19.0.1","destinationIP":"1.2.3.4","sourcePort":"50000","destinationPort":"443","host":"www.tiktok.com","processPath":"/Applications/TikTok.app/Contents/MacOS/TikTok (user)"},
           "upload":100,"download":900,"start":"2026-09-29T00:00:00.123456+03:00","chains":["via-happ","pool-video"],"rule":"rule_set=svc-vpn-video => route(pool-video)"},
          {"id":"def","metadata":{"network":"udp","destinationIP":"9.9.9.9","destinationPort":"53","host":"","processPath":""},"upload":1,"download":2,"start":"2026-09-29T00:00:01Z","chains":["direct-phys"],"rule":"final"}]}
        """
        let body = Data(json.utf8)
        let http = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        let srv = try await TestServer(.reply(http, delayMs: 0)); defer { srv.stop() }
        let snap = try await ClashClient(port: srv.port, secret: "s").connections()
        #expect(snap.uploadTotal == 500 && snap.downloadTotal == 1000 && snap.connections.count == 2)
        let a = snap.connections[0]
        #expect(a.host == "www.tiktok.com" && a.port == 443 && a.appName == "TikTok" && a.path == .vpn && a.processPath == "/Applications/TikTok.app/Contents/MacOS/TikTok")
        #expect(snap.connections[1].host == "9.9.9.9" && snap.connections[1].processPath == nil)
        #expect(a.start < Date())
        #expect(String(decoding: srv.received, as: UTF8.self).contains("Authorization: Bearer s"))
    }
}

@Suite("Diagnostics helpers") struct DiagnosticsHelperTests {
    @Test func tiktokRegionParsing() {
        #expect(Diagnostics.tiktokRegions(in: #"...,"region":"cz","x":1,"regionCode":"CZ","appRegion":"DE"..."#) == ["CZ", "DE"])
        #expect(Diagnostics.tiktokRegions(in: "<html>stub</html>") == [])
        #expect(Diagnostics.tiktokRegions(in: #"{"region":"RU"}"#) == ["RU"])
    }
    @Test func cloudflareTrace() {
        #expect(Diagnostics.cloudflareLoc("fl=1\nip=1.2.3.4\nloc=DE\ncolo=FRA\n") == "DE")
        #expect(Diagnostics.cloudflareLoc("nothing") == nil)
    }
}

@Suite("Community lists & backup", .serialized) struct CommunityAndBackupTests {
    func tmp() -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("wp-x-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }

    @Test(.enabled(if: Vendor.hasSingBox, "vendor/sing-box missing: run scripts/fetch-vendor.sh")) func updaterDownloadsValidatesAndSkipsUnchanged() async throws {
        let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sb = pkg.appendingPathComponent("vendor/sing-box")
        try #require(FileManager.default.isExecutableFile(atPath: sb.path), "vendor/sing-box not present")
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("s.json"); try Data(#"{"version":5,"rules":[{"domain_suffix":["x.example"]}]}"#.utf8).write(to: src)
        let srs = dir.appendingPathComponent("s.srs")
        try #require(runProcess(sb.path, ["rule-set", "compile", "--output", srs.path, src.path]).code == 0)
        let body = try Data(contentsOf: srs)
        let http = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        let good = try await TestServer(.reply(http, delayMs: 0)); defer { good.stop() }
        let junk = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8)
        let bad = try await TestServer(.reply(junk, delayMs: 0)); defer { bad.stop() }

        let one = [CommunityList.all[0]]
        var r = await CommunityListUpdater.refresh(home: dir, socks: nil, lists: one, baseOverride: "http://127.0.0.1:\(good.port)/", mirrorOverride: "http://127.0.0.1:\(good.port)/")
        #expect(r.updated == [one[0].id] && r.failed.isEmpty)
        #expect(CommunityListUpdater.installed(home: dir).map(\.id) == [one[0].id])
        r = await CommunityListUpdater.refresh(home: dir, socks: nil, lists: one, baseOverride: "http://127.0.0.1:\(good.port)/", mirrorOverride: "http://127.0.0.1:\(good.port)/")
        #expect(r.unchanged == [one[0].id], "fresh enough: no second download")
        // garbage that does not look like a rule-set is refused and never installed
        let dir2 = tmp(); defer { try? FileManager.default.removeItem(at: dir2) }
        r = await CommunityListUpdater.refresh(home: dir2, socks: nil, lists: one, baseOverride: "http://127.0.0.1:\(bad.port)/", mirrorOverride: "http://127.0.0.1:\(bad.port)/")
        #expect(r.failed.count == 1 && CommunityListUpdater.installed(home: dir2).isEmpty)
    }

    @Test func backupRoundTripsAndRejectsBadServerLinks() throws {
        let a = tmp(), b = tmp(); defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        var s = AppSettings(); s.playbooks = ["tiktok"]; s.servicePolicies = ["youtube": "direct"]; s.save(to: a)
        try "vpn example.org\nvpn app:/Applications/Discord.app\n".write(to: a.appendingPathComponent("rules.txt"), atomically: true, encoding: .utf8)
        ServerStore.save([ServerEntry(name: "ok", link: "trojan://p@a.example.com:443"), ServerEntry(name: "bad", link: "garbage")], to: a)
        let file = a.appendingPathComponent("backup.json")
        try Backup.export(home: a, to: file)
        let msg = try Backup.restore(from: file, home: b)
        #expect(msg.contains("правил: 2") && msg.contains("серверов: 1"))
        #expect(AppSettings.load(from: b).playbooks == ["tiktok"] && AppSettings.load(from: b).servicePolicies?["youtube"] == "direct")
        #expect(ServerStore.load(from: b).map(\.name) == ["ok"])
        #expect(ManualRule.parseAll((try? String(contentsOf: b.appendingPathComponent("rules.txt"), encoding: .utf8)) ?? "").count == 2)
    }
}
