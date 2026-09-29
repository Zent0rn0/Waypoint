import Testing
import Foundation
@testable import WaypointCore

@Suite("Connection rules") struct ConnectionRuleTests {
    @Test func normalizesAndValidates() {
        #expect(ConnectionRule.normalizeSite("https://www.YouTube.com/watch?v=1") == "youtube.com")
        #expect(ConnectionRule.normalizeSite("1.2.3.4") == "1.2.3.4/32")
        #expect(ConnectionRule.normalizeSite("10.0.0.0/8") == "10.0.0.0/8")
        #expect(ConnectionRule.normalizeSite("bad host\"") == nil)
        #expect(ConnectionRule(app: nil, site: nil, target: .vpn) == nil)
        #expect(ConnectionRule(app: "/Applications/Waypoint.app", site: nil, target: .vpn) == nil, "routing Waypoint itself would loop")
        #expect(ConnectionRule(app: "relative/path", site: nil, target: .vpn) == nil)
        let r = ConnectionRule(app: "/Applications/Discord.app/Contents/Frameworks/Helper.app", site: "discord.com", target: .direct)
        #expect(r?.app == "/Applications/Discord.app" && r?.tier == .pair)
    }

    @Test func targetRoundTripsAsString() throws {
        for t in [ConnectionTarget.direct, .vpn, .client, .block, .server("abc-1")] {
            let d = try JSONEncoder().encode([t])
            #expect(try JSONDecoder().decode([ConnectionTarget].self, from: d) == [t])
        }
        #expect(ConnectionTarget(raw: "server:") == nil)
    }

    @Test func matching() {
        let r = ConnectionRule(app: "/Applications/Discord.app", site: "discord.com", target: .direct)!
        #expect(r.matches(app: "/Applications/Discord.app/Contents/MacOS/Discord", host: "gateway.discord.com"))
        #expect(!r.matches(app: "/Applications/Safari.app/Contents/MacOS/Safari", host: "discord.com"))
        #expect(!r.matches(app: "/Applications/Discord.app/Contents/MacOS/Discord", host: "notdiscord.com"))
        let ip = ConnectionRule(app: nil, site: "149.154.160.0/20", target: .vpn)!
        #expect(ip.matches(app: nil, host: "149.154.167.41") && !ip.matches(app: nil, host: "8.8.8.8"))
    }

    @Test func storeDropsInvalidAndDuplicateEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wp-conn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"site":"a.com","target":"vpn"},{"site":"a.com","target":"direct"},{"app":"../x","target":"vpn"},{"site":"b.com","target":"nope"},{"site":"c.com","target":"client"}]"#.utf8)
            .write(to: dir.appendingPathComponent(ConnectionRuleStore.fileName))
        #expect(ConnectionRuleStore.load(from: dir).map(\.target) == [.vpn, .client], "a bad entry is skipped, the rest still applies")
    }

    // MARK: tunnel

    func plan() -> ConnectionPlan {
        let rules = [ConnectionRule(app: "/Applications/Discord.app", site: "discord.com", target: .direct)!,
                     ConnectionRule(app: "/Applications/Telegram.app", site: nil, target: .server("de"))!,
                     ConnectionRule(app: nil, site: "youtube.com", target: .client)!,
                     ConnectionRule(app: nil, site: "example.org", target: .server("gone"))!]
        return ConnectionPlan.build(rules, servers: [(tag: "srv-1", id: "nl"), (tag: "srv-2", id: "de")])
    }

    @Test func planGroupsByTierAndTarget() throws {
        let p = plan()
        #expect(p.serverTags == ["srv-2"])
        func rules(_ n: String) throws -> [[String: Any]] { (try JSONSerialization.jsonObject(with: p.files[n]!) as! [String: Any])["rules"] as! [[String: Any]] }
        let pair = try rules("conn-pair-direct")[0]
        #expect(pair["process_path_regex"] as? [String] == [#"^/Applications/Discord\.app/"#] && pair["domain_suffix"] as? [String] == ["discord.com"])
        #expect(try rules("conn-app-srv-2")[0]["process_path_regex"] != nil)
        #expect(try rules("conn-site-client")[0]["domain_suffix"] as? [String] == ["youtube.com"])
        #expect(try rules("conn-site-vpn")[0]["domain_suffix"] as? [String] == ["example.org"], "a server that is off or gone falls back to the best VPN")
        #expect(try rules("conn-app-block")[0]["domain"] as? [String] == ["waypoint-placeholder.invalid"])
    }

    @Test func tunnelOrderPairThenAppThenSite() throws {
        let p = TunnelParams(physicalInterface: "en0", happInterface: "utun7", racePort: 7810, directDNS: "192.168.1.1", ruleSetDir: "/tmp/rs", cachePath: "/tmp/c.db")
        let srv = try ShareLink.parse("trojan://s3cret@c.example.com:443?sni=c.example.com#c")
        let c = try JSONSerialization.jsonObject(with: TunnelConfig.generate(p, policy: CompiledPolicy(), servers: [("srv-2", srv)], community: [],
                                                                               connectionServers: ["srv-2", "srv-9", "bad\"tag"])) as! [String: Any]
        let rules = (c["route"] as! [String: Any])["rules"] as! [[String: Any]]
        func index(_ set: String) -> Int? { rules.firstIndex { ($0["rule_set"] as? [String]) == [set] } }
        let pair = try #require(index("conn-pair-direct")), app = try #require(index("conn-app-srv-2")), site = try #require(index("conn-site-client"))
        let appRules = try #require(index("app-direct")), manual = try #require(index("manual-vpn")), learned = try #require(index("learned-vpn"))
        #expect(pair < appRules && appRules < app && app < manual && manual < site && site < learned)
        #expect(rules[app]["outbound"] as? String == "srv-2")
        #expect(rules[try #require(index("conn-app-srv-9"))]["outbound"] as? String == "pool-general", "a server shed by the pre-flight falls back")
        #expect(index("conn-app-bad\"tag") == nil, "only srv-N tags reach the config")
        #expect(rules[try #require(index("conn-site-client"))]["outbound"] as? String == "via-happ")
        #expect(rules[try #require(index("conn-pair-block"))]["action"] as? String == "reject")
    }

    @Test(.enabled(if: Vendor.hasSingBox, "vendor/sing-box missing: run scripts/fetch-vendor.sh")) func realSingBoxAcceptsConnectionRules() throws {
        let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sb = pkg.appendingPathComponent("vendor/sing-box")
        try #require(FileManager.default.isExecutableFile(atPath: sb.path), "vendor/sing-box not present")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wp-connsb-\(UUID().uuidString)")
        let rs = dir.appendingPathComponent("rs")
        try FileManager.default.createDirectory(at: rs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = plan()
        for (n, d) in TunnelConfig.ruleSets(rules: RuleEngine(directory: nil, region: .russia), policy: CompiledPolicy(), connections: plan) {
            try d.write(to: rs.appendingPathComponent("\(n).json"))
        }
        let servers = [("srv-1", try ShareLink.parse("trojan://s3cret@c.example.com:443?sni=c.example.com#c")),
                       ("srv-2", try ShareLink.parse("hy2://pw@d.example.com:8443?sni=d.example.com#d"))]
        for withServers in [true, false] {
            var p = TunnelParams(physicalInterface: "en0", happInterface: "utun7", racePort: 7810, directDNS: "192.168.1.1",
                                 ruleSetDir: rs.path, cachePath: dir.appendingPathComponent("c.db").path, tun: false)
            p.apiSecret = "0123456789abcdef0123456789abcdef"
            let cfg = dir.appendingPathComponent("cfg.json")
            try TunnelConfig.generate(p, policy: CompiledPolicy(), servers: withServers ? servers : [], community: [], connectionServers: plan.serverTags).write(to: cfg)
            let r = runProcess(sb.path, ["check", "-c", cfg.path])
            #expect(r.code == 0, "sing-box check failed (servers \(withServers)): \(r.out)\(r.err)")
        }
    }
}
