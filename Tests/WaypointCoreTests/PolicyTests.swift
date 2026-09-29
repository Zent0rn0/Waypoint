import Testing
import Foundation
@testable import WaypointCore

@Suite("Share links") struct ShareLinkTests {
    let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"

    @Test func vlessReality() throws {
        let p = try ShareLink.parse("vless://\(uuid)@example.org:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#My%20Server")
        #expect(p.name == "My Server" && p.host == "example.org" && p.port == 443 && p.proto == "vless")
        #expect(p.outbound["uuid"] as? String == uuid && p.outbound["flow"] as? String == "xtls-rprx-vision")
        let tls = p.outbound["tls"] as! [String: Any]
        #expect((tls["reality"] as! [String: Any])["public_key"] as? String == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        #expect(tls["server_name"] as? String == "www.microsoft.com")
    }

    @Test func vlessWebSocketAndGRPC() throws {
        let ws = try ShareLink.parse("vless://\(uuid)@1.2.3.4:8443?type=ws&security=tls&sni=cdn.example.com&host=cdn.example.com&path=%2Fws#ws")
        #expect((ws.outbound["transport"] as! [String: Any])["type"] as? String == "ws")
        #expect(((ws.outbound["transport"] as! [String: Any])["headers"] as! [String: String])["Host"] == "cdn.example.com")
        let g = try ShareLink.parse("vless://\(uuid)@h.example.com:443?type=grpc&security=tls&serviceName=svc#g")
        #expect((g.outbound["transport"] as! [String: Any])["service_name"] as? String == "svc")
    }

    @Test func trojanHysteria2ShadowsocksVmess() throws {
        let t = try ShareLink.parse("trojan://s3cret@t.example.com:443?sni=t.example.com#t")
        #expect(t.proto == "trojan" && t.outbound["password"] as? String == "s3cret")
        let h = try ShareLink.parse("hy2://pw@h.example.com:8443?sni=h.example.com&obfs=salamander&obfs-password=xyz#h")
        #expect(h.proto == "hysteria2" && (h.outbound["obfs"] as! [String: Any])["type"] as? String == "salamander")
        let userinfo = Data("chacha20-ietf-poly1305:pa55".utf8).base64EncodedString()
        let s = try ShareLink.parse("ss://\(userinfo)@s.example.com:8388#ss")
        #expect(s.proto == "shadowsocks" && s.outbound["method"] as? String == "chacha20-ietf-poly1305")
        let legacy = Data("aes-256-gcm:pw@9.9.9.9:1234".utf8).base64EncodedString()
        #expect(try ShareLink.parse("ss://\(legacy)#old").port == 1234)
        let vm = ["add": "v.example.com", "port": "443", "id": uuid, "aid": "0", "net": "ws", "tls": "tls", "path": "/p", "host": "v.example.com", "ps": "vm"] as [String: Any]
        let b = try JSONSerialization.data(withJSONObject: vm).base64EncodedString()
        #expect(try ShareLink.parse("vmess://\(b)").proto == "vmess")
    }

    @Test func rejectsMalformedAndDangerousInput() {
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("http://example.com") }
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("vless://not-a-uuid@example.org:443") }
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("vless://\(uuid)@exa mple.org:443") }
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("vless://\(uuid)@example.org:99999") }
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("vless://\(uuid)@example.org:443?type=ws&path=%22%2C%22x") }   // quote in path
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("ss://YWVzLTI1Ni1nY206cHc@h.example.com:1?plugin=obfs") }         // plugins unsupported
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("vless://\(uuid)@example.org:443?security=reality&pbk=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&sid=zz") }   // non-hex short id
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("vless://\(uuid)@example.org:443?security=reality&pbk=tooshort&sid=ab") }        // a bad key would fail the whole tunnel config
    }

    @Test func storeSkipsBadEntriesAndTagsStably() {
        let list = [ServerEntry(name: "a", link: "trojan://p@a.example.com:443"), ServerEntry(name: "bad", link: "nope"),
                    ServerEntry(name: "off", link: "trojan://p@b.example.com:443", enabled: false), ServerEntry(name: "c", link: "trojan://p@c.example.com:443")]
        #expect(ServerStore.outbounds(list).map(\.tag) == ["srv-1", "srv-2"])
    }
}

@Suite("Policy") struct PolicyTests {
    func compile(_ f: (inout AppSettings) -> Void = { _ in }, manual: [ManualRule] = []) -> CompiledPolicy {
        var s = AppSettings(); s.region = .russia; f(&s); return PolicyCompiler.compile(settings: s, manual: manual)
    }

    @Test func defaultsComeFromTheCatalogOnlyInTheRussianRegion() {
        let p = compile()
        #expect(p.starterVPN[.video]!.contains("youtube.com") && p.starterVPN[.chat]!.contains("discord.media"))
        #expect(p.starterVPNCIDR[.chat]!.contains("149.154.160.0/20"))
        #expect(p.starterDirect.contains("ru") && p.starterDirect.contains("sberbank.ru"))
        #expect(p.svcVPN.isEmpty && p.svcDirect.isEmpty)                                   // no explicit choices yet
        #expect(compile { $0.region = Region.none }.starterVPN.isEmpty)
    }

    @Test func tiktokScenarioForcesEveryTikTokDomainThroughTheVPN() {
        let p = compile { $0.playbooks = ["tiktok"] }
        let vpn = p.svcVPN[.video] ?? []
        for d in ["tiktok.com", "tiktokv.com", "tiktokcdn.com", "tiktokcdn-us.com", "byteoversea.com", "ibytedtos.com", "muscdn.com", "musical.ly"] { #expect(vpn.contains(d), "\(d)") }
        #expect(!p.starterVPN.values.flatMap { $0 }.contains("tiktok.com"), "an explicit choice must not also sit in the default tier")
        let e = RuleEngine(directory: nil, region: .russia)
        var s = AppSettings(); s.playbooks = ["tiktok"]; e.configure(settings: s)
        #expect(e.decide(host: "www.tiktok.com", port: 443) == Decision(.vpn, .manual, allowFallback: true))
        #expect(e.decide(host: "v16-webapp.tiktokcdn.com", port: 443).action == .vpn)
        // Even a wrongly learned "direct-ish" history cannot pull it back: explicit beats learned.
    }

    @Test func explicitUserChoiceBeatsScenariosAndScenariosBeatDefaults() {
        var p = compile { $0.playbooks = ["media"]; $0.servicePolicies = ["youtube": "direct"] }
        #expect(p.svcDirect.contains("youtube.com") && !(p.svcVPN[.video] ?? []).contains("youtube.com"))
        #expect((p.svcVPN[.video] ?? []).contains("twitch.tv"))
        p = compile { $0.servicePolicies = ["telegram": "block"] }
        #expect(p.svcBlock.contains("t.me"))
    }

    @Test func strictScenarioProtectsBanksFromWronglyLearnedVerdicts() {
        let e = RuleEngine(directory: nil, region: .russia)
        var s = AppSettings(); s.playbooks = ["strict-ru"]; e.configure(settings: s)
        e.noteDirectBlocked(host: "www.sberbank.ru"); e.noteDirectBlocked(host: "online.sberbank.ru")    // a (false) learned "vpn"
        #expect(e.decide(host: "online.sberbank.ru", port: 443) == Decision(.direct, .manual))
    }

    @Test func modesAndFlagsFromScenarios() {
        #expect(compile { $0.playbooks = ["lockdown"] }.finalMode == .allVPN)
        #expect(compile { $0.playbooks = ["saver"] }.finalMode == .savings)
        #expect(compile { $0.playbooks = ["saver", "lockdown"] }.finalMode == .allVPN)      // the safer one wins
        #expect(compile { $0.playbooks = ["voice"] }.udpViaVPN)
        #expect(compile { $0.tunnelUDPViaVPN = true }.udpViaVPN)
        #expect(compile { $0.playbooks = ["abroad"] }.region == Region.none)
        #expect(compile { $0.playbooks = ["abroad"] }.starterVPN.isEmpty)
    }

    @Test func appRulesParseWithSpacesAndValidate() {
        #expect(ManualRule.parse("vpn app:/Applications/Discord.app") == .init(route: .vpn, kind: .app, value: "/Applications/Discord.app"))
        #expect(ManualRule.parse("direct app:/Applications/Яндекс Музыка.app/Contents/MacOS/Yandex # note")?.value == "/Applications/Яндекс Музыка.app")
        #expect(ManualRule.parse("vpn app:/usr/bin/curl")?.value == "/usr/bin/curl")
        #expect(ManualRule.parse("vpn app:relative/path") == nil)
        #expect(ManualRule.parse("vpn app:/Applications/../etc/x.app") == nil)
        #expect(ManualRule.parse("vpn app:/Applications/Bad\".app") == nil)
        #expect(ManualRule.parse("vpn app:/Applications/Waypoint.app") == nil, "routing Waypoint itself would loop")
        #expect(ManualRule.parse("vpn app:/Applications/Happ.app/Contents/PlugIns/Tunnel.appex") == nil)
        let r = ManualRule.parse("vpn app:/Applications/Visual Studio Code.app")!
        #expect(ManualRule.parseAll(ManualRule.serialize([r])) == [r])
        #expect(AppPath.regex("/Applications/Discord.app") == "^/Applications/Discord\\.app/")
        #expect(AppPath.regex("/usr/bin/curl") == "^/usr/bin/curl$")
        #expect(AppPath.displayName("/Applications/Яндекс Музыка.app") == "Яндекс Музыка")
    }
}
