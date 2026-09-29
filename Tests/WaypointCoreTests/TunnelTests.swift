import Testing
import Foundation
@testable import WaypointCore

@Suite("Tunnel config") struct TunnelConfigTests {
    func params(tun: Bool = true) -> TunnelParams {
        TunnelParams(physicalInterface: "en0", happInterface: "utun7", racePort: 7810, directDNS: "192.168.31.1",
                     ruleSetDir: "/tmp/wp-rs", cachePath: "/tmp/wp-cache.db", tun: tun)
    }
    func json(_ p: TunnelParams) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: TunnelConfig.generate(p)) as! [String: Any]
    }

    @Test func structure() throws {
        let c = try json(params())
        let outbounds = (c["outbounds"] as! [[String: Any]])
        #expect(outbounds.map { $0["tag"] as! String } == ["direct-phys", "via-happ", "waypoint-race"])
        #expect(outbounds[0]["bind_interface"] as? String == "en0")          // direct = pinned to the physical NIC
        #expect(outbounds[1]["bind_interface"] as? String == "utun7")        // VPN = enter Happ's own tunnel (TCP and UDP)
        let route = c["route"] as! [String: Any]
        #expect(route["final"] as? String == "direct-phys")
        #expect((c["inbounds"] as! [[String: Any]])[0]["type"] as? String == "tun")
        let excluded = (c["inbounds"] as! [[String: Any]])[0]["route_exclude_address"] as! [String]
        #expect(excluded.contains("224.0.0.0/4") && excluded.contains("100.64.0.0/10"))
        #expect(!excluded.contains("192.168.0.0/16"), "the LAN router is the DNS server: its queries must enter the tunnel to be hijacked")
        let dns = c["dns"] as! [String: Any]
        #expect(dns["final"] as? String == "dns-direct")                      // sing-box forbids fakeip as the default server
        #expect(((dns["servers"] as! [[String: Any]]).contains { $0["type"] as? String == "fakeip" }))
    }

    @Test func fakeIPRangeDoesNotCollideWithHapps() throws {
        let dns = try json(params())["dns"] as! [String: Any]
        let fake = (dns["servers"] as! [[String: Any]]).first { $0["type"] as? String == "fakeip" }!
        #expect(fake["inet4_range"] as? String == "198.19.0.0/16")           // Happ's own fake range is 198.18.0.0/16
    }

    @Test func ruleOrderIsMostSpecificFirst() throws {
        let rules = (try json(params())["route"] as! [String: Any])["rules"] as! [[String: Any]]
        func idx(_ f: ([String: Any]) -> Bool) -> Int { rules.firstIndex(where: f)! }
        let hijack = idx { $0["action"] as? String == "hijack-dns" }
        let priv = idx { $0["ip_is_private"] as? Bool == true }
        let manualVPN = idx { ($0["rule_set"] as? [String]) == ["manual-vpn"] }
        let learned = idx { ($0["rule_set"] as? [String]) == ["learned-vpn"] }
        let starterVPN = idx { ($0["rule_set"] as? [String]) == ["starter-vpn-general"] }
        let quic = idx { ($0["network"] as? String) == "udp" }
        let race = idx { ($0["outbound"] as? String) == "waypoint-race" }
        let raceRule = rules.first { ($0["outbound"] as? String) == "waypoint-race" }!
        #expect((raceRule["protocol"] as? [String]) == ["tls", "http"], "unidentified TCP on 80/443 must never reach the racer")
        #expect(hijack < priv && priv < manualVPN && manualVPN < learned && learned < starterVPN && starterVPN < quic && quic < race)
    }

    @Test func udpViaVPNIsOptInAndSitsBeforeTheTCPRace() throws {
        func rules(_ udp: Bool) throws -> [[String: Any]] { var p = params(); p.udpViaVPN = udp; return (try json(p)["route"] as! [String: Any])["rules"] as! [[String: Any]] }
        #expect(try !rules(false).contains { $0["network"] as? String == "udp" && $0["outbound"] as? String == "via-happ" })
        let on = try rules(true)
        let udp = on.firstIndex { $0["network"] as? String == "udp" && $0["outbound"] as? String == "via-happ" }!
        let quic = on.firstIndex { $0["network"] as? String == "udp" && $0["action"] as? String == "reject" }!
        #expect(quic < udp, "QUIC to undecided hosts must still be rejected, not sent through the VPN")
    }

    @Test func noTunModeUsesLocalInboundAndSkipsDNSHijack() throws {
        let c = try json(params(tun: false))
        #expect((c["inbounds"] as! [[String: Any]])[0]["type"] as? String == "mixed")
        let rules = (c["route"] as! [String: Any])["rules"] as! [[String: Any]]
        #expect(!rules.contains { $0["action"] as? String == "hijack-dns" })
    }

    @Test func rejectsAnythingThatCouldSmuggleContentIntoARootConfig() {
        var p = params(); p.physicalInterface = "en0\", \"x\": \""
        #expect(throws: TunnelConfigError.self) { try TunnelConfig.generate(p) }
        p = params(); p.happInterface = "../etc"
        #expect(throws: TunnelConfigError.self) { try TunnelConfig.generate(p) }
        p = params(); p.directDNS = "evil.example"
        #expect(throws: TunnelConfigError.self) { try TunnelConfig.generate(p) }
        p = params(); p.racePort = 80
        #expect(throws: TunnelConfigError.self) { try TunnelConfig.generate(p) }
        #expect(TunnelConfig.isValidInterface("utun12") && TunnelConfig.isValidInterface("en0"))
        #expect(!TunnelConfig.isValidInterface("lo0") && !TunnelConfig.isValidInterface("en0;rm"))
    }

    @Test func ruleSetsSanitizeAndMapRuleKinds() throws {
        let e = RuleEngine(directory: nil, region: .none)
        e.setManualRules([
            .init(route: .vpn, kind: .suffix, value: "good.example"),
            .init(route: .vpn, kind: .suffix, value: "bad domain\"],\"x"),          // must be dropped
            .init(route: .direct, kind: .exact, value: "api.bank.ru"),
            .init(route: .vpn, kind: .keyword, value: "tiktok"),
            .init(route: .block, kind: .cidr, value: "10.9.0.0/16"),
            .init(route: .vpn, kind: .exact, value: "1.2.3.4"),
        ], persist: false)
        e.noteDirectBlocked(host: "x.blocked.example"); e.noteDirectBlocked(host: "blocked.example")
        e.noteDirectBlocked(host: "149.154.167.1"); e.noteDirectBlocked(host: "149.154.167.2")
        let sets = TunnelConfig.ruleSets(rules: e, region: .russia)
        func rule(_ n: String) -> [String: Any] {
            let obj = try! JSONSerialization.jsonObject(with: sets[n]!) as! [String: Any]
            return (obj["rules"] as! [[String: Any]])[0]
        }
        func version(_ n: String) -> Int { ((try! JSONSerialization.jsonObject(with: sets[n]!)) as! [String: Any])["version"] as! Int }
        #expect(Set(TunnelConfig.sourceRuleSetTags + ConnectionPlan.fixedTags) == Set(sets.keys) && TunnelConfig.sourceRuleSetTags.allSatisfy { version($0) == 5 })
        #expect(rule("manual-vpn")["domain_suffix"] as? [String] == ["good.example"])
        #expect(rule("manual-vpn")["domain_keyword"] as? [String] == ["tiktok"])
        #expect(rule("manual-vpn")["ip_cidr"] as? [String] == ["1.2.3.4/32"])
        #expect(rule("manual-direct")["domain"] as? [String] == ["api.bank.ru"])
        #expect(rule("manual-block")["ip_cidr"] as? [String] == ["10.9.0.0/16"])
        #expect(rule("learned-vpn")["domain_suffix"] as? [String] == ["blocked.example"])
        #expect(rule("learned-vpn")["ip_cidr"] as? [String] == ["149.154.167.0/24"])
        #expect((rule("starter-vpn-chat")["domain_suffix"] as! [String]).contains("discord.media"))
        #expect((rule("starter-direct")["domain_suffix"] as! [String]).contains("ru"))
        #expect((rule("starter-vpn-chat")["ip_cidr"] as! [String]).contains("149.154.160.0/20"))
    }

    @Test func emptyRuleSetsNeverMatchEverything() throws {
        let sets = TunnelConfig.ruleSets(rules: RuleEngine(directory: nil, region: .none), region: .none)
        let r = (((try JSONSerialization.jsonObject(with: sets["learned-vpn"]!)) as! [String: Any])["rules"] as! [[String: Any]])[0]
        #expect(r["domain"] as? [String] == ["waypoint-placeholder.invalid"])
    }

    @Test(.enabled(if: Vendor.hasSingBox, "vendor/sing-box missing: run scripts/fetch-vendor.sh")) func realSingBoxAcceptsTheGeneratedConfig() throws {
        let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sb = pkg.appendingPathComponent("vendor/sing-box")
        try #require(FileManager.default.isExecutableFile(atPath: sb.path), "vendor/sing-box not present")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wp-tun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("rs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (n, d) in TunnelConfig.ruleSets(rules: RuleEngine(directory: nil, region: .russia), region: .russia) { try d.write(to: dir.appendingPathComponent("rs/\(n).json")) }
        for tun in [true, false] {
            var p = params(tun: tun); p.ruleSetDir = dir.appendingPathComponent("rs").path; p.cachePath = dir.appendingPathComponent("c.db").path
            let cfg = dir.appendingPathComponent("config-\(tun).json")
            try TunnelConfig.generate(p).write(to: cfg)
            let r = runProcess(sb.path, ["check", "-c", cfg.path])
            #expect(r.code == 0, "sing-box check (tun=\(tun)) failed: \(r.out)\(r.err)")
        }
    }

    // MARK: v2

    func servers() throws -> [(tag: String, server: ParsedServer)] {
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        let ss = Data("chacha20-ietf-poly1305:pa55".utf8).base64EncodedString()
        let links = ["vless://\(uuid)@a.example.com:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#a",
                     "vless://\(uuid)@b.example.com:443?type=ws&security=tls&sni=b.example.com&host=b.example.com&path=%2Fws#b",
                     "trojan://s3cret@c.example.com:443?sni=c.example.com#c", "hy2://pw@d.example.com:8443?sni=d.example.com#d", "ss://\(ss)@e.example.com:8388#e",
                     "https://alice:pw@f.example.com:8443#f"]
        return try links.enumerated().map { ("srv-\($0.offset + 1)", try ShareLink.parse($0.element)) }
    }

    func policy(_ playbooks: [String], apps: [ManualRule] = []) -> CompiledPolicy {
        var s = AppSettings(); s.playbooks = playbooks
        return PolicyCompiler.compile(settings: s, manual: apps)
    }

    @Test func withoutServersEveryVPNRuleGoesStraightToTheVPNClient() throws {
        let c = try JSONSerialization.jsonObject(with: TunnelConfig.generate(params(), policy: policy(["tiktok"]), servers: [], community: [])) as! [String: Any]
        let outs = (c["outbounds"] as! [[String: Any]]).map { $0["tag"] as! String }
        #expect(!outs.contains { $0.hasPrefix("pool-") })
        let rules = (c["route"] as! [String: Any])["rules"] as! [[String: Any]]
        #expect(rules.first { ($0["rule_set"] as? [String]) == ["svc-vpn-video"] }?["outbound"] as? String == "via-happ")
    }

    @Test func withServersEachClassGetsItsOwnUrltestPoolIncludingTheVPNClient() throws {
        let c = try JSONSerialization.jsonObject(with: TunnelConfig.generate(params(), policy: policy(["tiktok", "voice"]), servers: servers(), community: [])) as! [String: Any]
        let outs = c["outbounds"] as! [[String: Any]]
        for cls in PoolClass.allCases {
            let g = outs.first { $0["tag"] as? String == "pool-\(cls.rawValue)" }!
            #expect(g["type"] as? String == "urltest" && (g["outbounds"] as! [String]).first == "via-happ")
            #expect((g["outbounds"] as! [String]).count == 7)                        // the VPN client + six servers
            #expect(g["url"] as? String == cls.testURL)
        }
        let rules = (c["route"] as! [String: Any])["rules"] as! [[String: Any]]
        #expect(rules.first { ($0["rule_set"] as? [String]) == ["svc-vpn-video"] }?["outbound"] as? String == "pool-video")   // TikTok → the best server for video
        #expect(rules.first { ($0["rule_set"] as? [String]) == ["svc-vpn-chat"] }?["outbound"] as? String == "pool-chat")
        // servers are dialled through the real NIC, and only the racer's loopback hop is pinned to lo0
        #expect((c["route"] as! [String: Any])["default_interface"] as? String == "en0")
        #expect(outs.first { $0["tag"] as? String == "waypoint-race" }?["bind_interface"] as? String == "lo0")
    }

    @Test func appRulesBeatDomainRulesAndUseBundleRegex() throws {
        let apps = [ManualRule.parse("vpn app:/Applications/Discord.app")!, ManualRule.parse("direct app:/Applications/Яндекс Музыка.app")!, ManualRule.parse("block app:/usr/bin/nc")!]
        let pol = policy([], apps: apps)
        let e = RuleEngine(directory: nil, region: .none); e.setManualRules(apps, persist: false)
        let sets = TunnelConfig.ruleSets(rules: e, policy: pol)
        func regexes(_ n: String) -> [String] { ((try! JSONSerialization.jsonObject(with: sets[n]!)) as! [String: Any])["rules"] .flatMap { ($0 as! [[String: Any]])[0]["process_path_regex"] as? [String] } ?? [] }
        #expect(regexes("app-vpn") == ["^/Applications/Discord\\.app/"])
        #expect(regexes("app-direct") == ["^/Applications/Яндекс Музыка\\.app/"])
        #expect(regexes("app-block") == ["^/usr/bin/nc$"])
        let c = try JSONSerialization.jsonObject(with: TunnelConfig.generate(params(), policy: pol, servers: [], community: [])) as! [String: Any]
        let rules = (c["route"] as! [String: Any])["rules"] as! [[String: Any]]
        let i = { (t: String) in rules.firstIndex { ($0["rule_set"] as? [String]) == [t] }! }
        #expect(i("app-direct") < i("manual-direct") && i("app-vpn") < i("manual-vpn") && i("app-vpn") < i("svc-direct"))
        #expect((c["route"] as! [String: Any])["find_process"] as? Bool == true)
    }

    @Test func lockdownAndSaverModesChangeTheTail() throws {
        func cfg(_ pb: [String]) throws -> [String: Any] { try JSONSerialization.jsonObject(with: TunnelConfig.generate(params(), policy: policy(pb), servers: [], community: [])) as! [String: Any] }
        let all = try cfg(["lockdown"])
        #expect((all["route"] as! [String: Any])["final"] as? String == "via-happ")
        #expect((all["dns"] as! [String: Any])["final"] as? String == "dns-vpn")
        #expect(!((all["route"] as! [String: Any])["rules"] as! [[String: Any]]).contains { $0["outbound"] as? String == "waypoint-race" })
        let saver = try cfg(["saver"])
        #expect((saver["route"] as! [String: Any])["final"] as? String == "direct-phys")
        let sr = (saver["route"] as! [String: Any])["rules"] as! [[String: Any]]
        #expect(!sr.contains { $0["outbound"] as? String == "waypoint-race" } && !sr.contains { $0["action"] as? String == "reject" && $0["port"] as? Int == 443 })
    }

    @Test func apiIsLoopbackWithSecretAndValidated() throws {
        var p = params(); p.apiSecret = "0123456789abcdef0123456789abcdef"
        let c = try JSONSerialization.jsonObject(with: TunnelConfig.generate(p)) as! [String: Any]
        let api = (c["experimental"] as! [String: Any])["clash_api"] as! [String: Any]
        #expect(api["external_controller"] as? String == "127.0.0.1:9097" && api["secret"] as? String == p.apiSecret)
        p.apiSecret = "x\"; drop"
        #expect(throws: TunnelConfigError.self) { try TunnelConfig.generate(p) }
    }

    @Test(.enabled(if: Vendor.hasSingBox, "vendor/sing-box missing: run scripts/fetch-vendor.sh")) func realSingBoxAcceptsEveryFeatureAtOnce() throws {
        let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sb = pkg.appendingPathComponent("vendor/sing-box")
        try #require(FileManager.default.isExecutableFile(atPath: sb.path), "vendor/sing-box not present")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wp-v2-\(UUID().uuidString)")
        let rs = dir.appendingPathComponent("rs")
        try FileManager.default.createDirectory(at: rs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let apps = [ManualRule.parse("vpn app:/Applications/Discord.app")!, ManualRule.parse("direct app:/Applications/Яндекс Музыка.app")!]
        let e = RuleEngine(directory: nil, region: .russia); e.setManualRules(apps + [ManualRule.parse("vpn example.org")!], persist: false)
        e.noteDirectBlocked(host: "learned.example"); e.noteDirectBlocked(host: "learned.example")
        for pb in [["tiktok", "voice", "ai", "media", "strict-ru"], ["lockdown"], ["saver"], []] {
            let pol = policy(pb, apps: apps)
            for (n, d) in TunnelConfig.ruleSets(rules: e, policy: pol) { try d.write(to: rs.appendingPathComponent("\(n).json")) }
            // real compiled binary lists under every community name (the format sing-box itself produces)
            let src = rs.appendingPathComponent("src.json"); try Data(#"{"version":5,"rules":[{"domain_suffix":["community.example"]}]}"#.utf8).write(to: src)
            for l in CommunityList.all {
                let r = runProcess(sb.path, ["rule-set", "compile", "--output", rs.appendingPathComponent(l.file).path, src.path])
                try #require(r.code == 0, "compile failed: \(r.err)")
            }
            for tun in [true, false] {
                for withServers in [true, false] {
                    var p = params(tun: tun); p.ruleSetDir = rs.path; p.cachePath = dir.appendingPathComponent("c.db").path; p.apiSecret = "0123456789abcdef0123456789abcdef"; p.udpViaVPN = true
                    let cfg = dir.appendingPathComponent("cfg.json")
                    try TunnelConfig.generate(p, policy: pol, servers: withServers ? servers() : [], community: CommunityList.all).write(to: cfg)
                    let r = runProcess(sb.path, ["check", "-c", cfg.path])
                    #expect(r.code == 0, "sing-box check failed (playbooks \(pb), tun \(tun), servers \(withServers)): \(r.out)\(r.err)")
                }
            }
        }
    }
}
