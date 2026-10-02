import Testing
import Foundation
@testable import WaypointCore

@Suite("Subscriptions") struct SubscriptionTests {
    let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
    let pbk = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    var links: [String] {
        ["vless://\(uuid)@de.example.com:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=\(pbk)&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#%F0%9F%87%A9%F0%9F%87%AA%20Germany",
         "trojan://s3cret@nl.example.com:443?sni=nl.example.com#NL",
         "vless://\(uuid)@ru.example.com:443?type=xhttp&security=reality&sni=a.ru&pbk=\(pbk)&sid=ab#%F0%9F%87%B7%F0%9F%87%BA%20Russia"]
    }

    @Test func base64AndPlainLists() throws {
        let plain = links.joined(separator: "\n")
        for body in [plain, "# comment\n\n" + plain + "\n", Data(plain.utf8).base64EncodedString(),
                     Data(plain.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")] {
            let r = try Subscription.parse(Data(body.utf8))
            #expect(r.servers.map(\.server.host) == ["de.example.com", "nl.example.com", "ru.example.com"], "body: \(body.prefix(30))")
            #expect(r.skippedCount == 0)
            #expect(r.servers[2].server.xrayOnly, "xhttp is carried by the Xray helper")
            #expect(r.servers[0].server.name == "🇩🇪 Germany")
        }
    }

    @Test func recognisesWrongFormats() {
        #expect(throws: SubscriptionError.html) { try Subscription.parse(Data("<!DOCTYPE html><html>login</html>".utf8)) }
        #expect(throws: SubscriptionError.clash) { try Subscription.parse(Data("mixed-port: 7890\nproxies:\n  - name: a".utf8)) }
        #expect(throws: SubscriptionError.empty) { try Subscription.parse(Data("   ".utf8)) }
        #expect(throws: SubscriptionError.empty) { try Subscription.parse(Data("bm90aGluZyB1c2VmdWwgaGVyZQ==".utf8)) }   // base64 of prose
    }

    @Test func singBoxJSON() throws {
        let json = """
        {"outbounds":[
          {"type":"selector","tag":"proxy","outbounds":["de"]},
          {"type":"vless","tag":"🇩🇪 DE","server":"de.example.com","server_port":443,"uuid":"\(uuid)","flow":"xtls-rprx-vision",
           "tls":{"enabled":true,"server_name":"www.microsoft.com","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"\(pbk)","short_id":"6ba85179e30d4fc2"}}},
          {"type":"trojan","tag":"NL","server":"nl.example.com","server_port":443,"password":"pw","tls":{"enabled":true,"server_name":"nl.example.com"},
           "transport":{"type":"ws","path":"/ws","headers":{"Host":"cdn.example.com"}}},
          {"type":"shadowsocks","tag":"SS","server":"1.2.3.4","server_port":8388,"method":"chacha20-ietf-poly1305","password":"p"},
          {"type":"hysteria2","tag":"HY","server":"hy.example.com","server_port":8443,"password":"p","tls":{"enabled":true,"server_name":"hy.example.com"}},
          {"type":"direct","tag":"direct"},
          {"type":"wireguard","tag":"WG","server":"wg.example.com","server_port":51820}
        ]}
        """
        let r = try Subscription.parse(Data(json.utf8))
        #expect(r.servers.map(\.server.proto) == ["vless", "trojan", "shadowsocks", "hysteria2"])
        #expect(r.servers[0].server.name == "🇩🇪 DE")
        let tls = r.servers[0].server.outbound["tls"] as! [String: Any]
        #expect((tls["reality"] as! [String: Any])["public_key"] as? String == pbk)
        let tr = r.servers[1].server.outbound["transport"] as! [String: Any]
        #expect(tr["type"] as? String == "ws" && (tr["headers"] as! [String: String])["Host"] == "cdn.example.com")
        #expect(r.skippedCount == 1, "wireguard is reported, selector/direct are ignored")
    }

    @Test func xrayJSONArray() throws {
        func cfg(_ remarks: String, network: String, host: String) -> String {
            """
            {"remarks":"\(remarks)","outbounds":[
              {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"\(host)","port":443,"users":[{"id":"\(uuid)","flow":"xtls-rprx-vision","encryption":"none"}]}]},
               "streamSettings":{"network":"\(network)","security":"reality","realitySettings":{"serverName":"www.microsoft.com","publicKey":"\(pbk)","shortId":"ab12","fingerprint":"chrome"}}},
              {"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}]}
            """
        }
        let json = "[" + [cfg("🇩🇪 Германия", network: "raw", host: "de.example.com"), cfg("🇹🇷 Турция", network: "tcp", host: "tr.example.com"),
                          cfg("🇰🇿 Казахстан", network: "xhttp", host: "kz.example.com")].joined(separator: ",") + "]"
        let r = try Subscription.parse(Data(json.utf8))
        #expect(r.servers.map(\.server.name) == ["🇩🇪 Германия", "🇹🇷 Турция", "🇰🇿 Казахстан"])
        #expect(r.servers.prefix(2).allSatisfy { ($0.server.outbound["flow"] as? String) == "xtls-rprx-vision" })
        #expect(r.servers[2].server.xrayOnly)
    }

    @Test func providerHeaders() {
        let i = SubscriptionInfo.parse(header: "upload=1073741824; download=2147483648; total=107374182400; expire=1790000000")!
        #expect(i.used == 3_221_225_472 && i.total == 107_374_182_400 && i.expire == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(SubscriptionInfo.parse(header: "garbage") == nil)
        #expect(Subscription.decodeTitle("base64:" + Data("Мой VPN".utf8).base64EncodedString()) == "Мой VPN")
        #expect(Subscription.decodeTitle("My%20VPN") == "My VPN")
        #expect(Subscription.decodeTitle("bad\"title") == nil)
    }

    @Test func importLinksOfOtherClients() {
        let sub = "https://sub.example.com/api/sub/AbC123"
        let enc = sub.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(SubscriptionLink.classify(sub) == .subscription(sub))
        #expect(SubscriptionLink.classify("happ://add/\(sub)") == .subscription(sub))
        #expect(SubscriptionLink.classify("v2rayn://install-sub?url=\(enc)&name=x") == .subscription(sub))
        #expect(SubscriptionLink.classify("sing-box://import-remote-profile?url=\(enc)#My") == .subscription(sub))
        #expect(SubscriptionLink.classify("clash://install-config?url=\(enc)") == .subscription(sub))
        #expect(SubscriptionLink.classify("hiddify://import/\(sub)#name") == .subscription(sub))
        #expect(SubscriptionLink.classify("happ://crypt3/AbCdEf") == .encrypted)
        #expect(SubscriptionLink.classify("http://sub.example.com/api/sub/x") == .insecure)
        #expect(SubscriptionLink.classify("vless://\(uuid)@a.example.com:443") == .notASubscription)
        #expect(SubscriptionLink.classify("https://user:pw@proxy.example.com:8443") == .notASubscription)   // an HTTPS proxy
    }

    @Test func httpsProxyLinks() throws {
        let p = try ShareLink.parse("https://alice:s3cr%40t@proxy.example.com:8443#Office")
        #expect(p.proto == "https" && p.port == 8443 && p.name == "Office")
        #expect(p.outbound["type"] as? String == "http" && p.outbound["username"] as? String == "alice" && p.outbound["password"] as? String == "s3cr@t")
        #expect((p.outbound["tls"] as! [String: Any])["server_name"] as? String == "proxy.example.com")
        #expect((try ShareLink.parse("https://proxy.example.com")).port == 443)
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("https://sub.example.com/api/sub/token") }     // subscription, not a proxy
        #expect(throws: ShareLinkError.self) { try ShareLink.parse("http://proxy.example.com:8080") }
        #expect(Subscription.isSubscriptionURL("https://sub.example.com/sub?token=1") && !Subscription.isSubscriptionURL("https://u:p@h.example.com"))
    }

    @Test func russianServersAndMergeKeepUserChoices() throws {
        #expect(Subscription.looksRussian("🇷🇺 Москва") && Subscription.looksRussian("Russia #2") && Subscription.looksRussian("RU-1"))
        #expect(!Subscription.looksRussian("🇩🇪 Germany") && !Subscription.looksRussian("Rumania") && !Subscription.looksRussian("Trust"))
        let parsed = try Subscription.parse(Data(links.dropLast().joined(separator: "\n").utf8)).servers
        let ru = try ShareLink.parse("trojan://p@msk.example.com:443#%F0%9F%87%B7%F0%9F%87%BA%20Moscow")
        let fresh = parsed + [("trojan://p@msk.example.com:443#%F0%9F%87%B7%F0%9F%87%BA%20Moscow", ru)]
        var list = Subscription.merge(existing: [ServerEntry(name: "mine", link: "trojan://x@m.example.com:443")], subscription: "S", fresh: fresh, region: .russia)
        #expect(list.count == 4 && list[0].name == "mine" && list[0].source == nil)
        #expect(list.first { $0.name.contains("Moscow") }?.enabled == false, "servers in Russia start switched off")
        // the user switches Germany off; an update must keep that and keep the id
        let de = list.firstIndex { $0.name.contains("Germany") }!
        list[de].enabled = false
        let id = list[de].id
        let again = Subscription.merge(existing: list, subscription: "S", fresh: fresh, region: .russia)
        #expect(again.first { $0.name.contains("Germany") }?.enabled == false && again.first { $0.name.contains("Germany") }?.id == id)
        // servers that disappeared from the subscription are removed; hand-added ones stay
        let smaller = Subscription.merge(existing: again, subscription: "S", fresh: Array(fresh.prefix(1)), region: .russia)
        #expect(smaller.map(\.name) == ["mine", "🇩🇪 Germany"])
        // abroad: nothing is switched off for being in Russia
        let abroad = Subscription.merge(existing: [], subscription: "T", fresh: fresh, region: .none)
        #expect(abroad.allSatisfy { $0.enabled })
    }

    @Test func defaultEnabledIsCapped() throws {
        let many = (1...40).map { "trojan://p@s\($0).example.com:443#S\($0)" }
        let fresh = try many.map { ($0, try ShareLink.parse($0)) }
        let list = Subscription.merge(existing: [], subscription: "S", fresh: fresh, region: .russia)
        #expect(list.filter(\.enabled).count == Subscription.defaultEnabledLimit && list.count == 40)
    }

    @Test func staleness() {
        var e = SubscriptionEntry(url: "https://a.example.com/s")
        #expect(e.isStale())
        e.updated = Date().addingTimeInterval(-3600)
        #expect(!e.isStale())
        e.updateHours = 0                                     // clamped to at least an hour
        #expect(!e.isStale(now: e.updated!.addingTimeInterval(1800)))
        e.updateHours = 1
        #expect(e.isStale(now: e.updated!.addingTimeInterval(3700)))
        #expect(e.isStale(now: e.updated!.addingTimeInterval(3700), hours: 1), "the user's own interval overrides the provider's")
        #expect(!e.isStale(now: e.updated!.addingTimeInterval(1800), hours: 1))
    }
}

@Suite("Subscription fetch", .serialized) struct SubscriptionFetchTests {
    @Test func fetchesWithHeadersOverHTTP() async throws {
        let body = Data("trojan://pw@nl.example.com:443?sni=nl.example.com#NL\ntrojan://pw@de.example.com:443#DE\n".utf8).base64EncodedData()
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nsubscription-userinfo: upload=1; download=2; total=100; expire=1790000000\r\n" +
                   "profile-title: base64:\(Data("Провайдер".utf8).base64EncodedString())\r\nprofile-update-interval: 6\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let srv = try await TestServer(.reply(Data(head.utf8) + body, delayMs: 0)); defer { srv.stop() }
        let r = try await Subscription.fetch("http://127.0.0.1:\(srv.port)/sub/abc", socks: nil, allowLoopbackHTTP: true)
        #expect(r.parsed.servers.map(\.server.name) == ["NL", "DE"])
        #expect(r.title == "Провайдер" && r.info?.total == 100 && r.info?.used == 3 && r.updateHours == 6)
        let req = String(decoding: srv.received, as: UTF8.self)
        #expect(req.contains("User-Agent: Waypoint/0.2"), "honest user agent")
        #expect(!req.lowercased().contains("hwid"), "no device-id headers")
    }

    @Test func refusesPlainHTTPAndReportsHTTPErrors() async throws {
        await #expect(throws: SubscriptionError.notHTTPS) { try await Subscription.fetch("http://sub.example.com/x", socks: nil) }
        let srv = try await TestServer(.reply(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), delayMs: 0)); defer { srv.stop() }
        await #expect(throws: SubscriptionError.http(404)) { try await Subscription.fetch("http://127.0.0.1:\(srv.port)/sub/x", socks: nil, allowLoopbackHTTP: true) }
    }
}

@Suite("Xray engine") struct XrayEngineTests {
    let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
    let pbk = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    @Test func buildsValidatedOutbounds() throws {
        let x = try XrayLink.parse("vless://\(uuid)@de.example.com:443?type=xhttp&mode=auto&path=%2Fx&security=reality&sni=a.example.com&fp=firefox&pbk=\(pbk)&sid=ab12&flow=xtls-rprx-vision#DE")
        let st = x.outbound["streamSettings"] as! [String: Any]
        #expect(st["network"] as? String == "xhttp" && (st["xhttpSettings"] as! [String: Any])["mode"] as? String == "auto")
        #expect((st["realitySettings"] as! [String: Any])["publicKey"] as? String == pbk)
        #expect(throws: ShareLinkError.self) { try XrayLink.parse("vless://\(uuid)@de.example.com:443?type=ws&path=%22bad&security=none") }
        #expect(throws: ShareLinkError.self) { try XrayLink.parse("vless://\(uuid)@de.example.com:443?type=tcp&security=reality&pbk=short&sid=ab") }
        #expect(throws: ShareLinkError.self) { try XrayLink.parse("vless://\(uuid)@de.example.com:443?type=xhttp&mode=evil") }
    }

    @Test func configAndLoopbackOutbounds() throws {
        let link = "vless://\(uuid)@de.example.com:443?type=tcp&security=reality&sni=a.example.com&pbk=\(pbk)&sid=ab#DE"
        let data = try #require(XrayLink.config([(port: 24100, link: link)], interface: "en0"))
        let j = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ob = (j["outbounds"] as! [[String: Any]])[0]
        #expect(((ob["streamSettings"] as! [String: Any])["sockopt"] as! [String: Any])["interface"] as? String == "en0")
        #expect(((j["inbounds"] as! [[String: Any]])[0])["listen"] as? String == "127.0.0.1")
        #expect(XrayLink.config([(port: 24100, link: link)], interface: "en0; rm") == nil)
        var e = ServerEntry(name: "DE", link: link); e.engine = "xray"
        var list = [e]; ServerStore.assignPorts(&list)
        #expect(list[0].localPort == 24100)
        let o = ServerStore.outbounds(list)[0].parsed.outbound
        #expect(o["type"] as? String == "socks" && o["server"] as? String == "127.0.0.1" && o["bind_interface"] as? String == "lo0")
    }

    @Test(.enabled(if: Vendor.hasXray, "vendor/xray missing: run scripts/fetch-vendor.sh")) func realXrayAcceptsTheConfig() throws {
        let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let xr = pkg.appendingPathComponent("vendor/xray")
        try #require(FileManager.default.isExecutableFile(atPath: xr.path))
        let links = ["vless://\(uuid)@de.example.com:443?type=tcp&security=reality&sni=a.example.com&fp=firefox&pbk=\(pbk)&sid=ab&flow=xtls-rprx-vision#DE",
                     "vless://\(uuid)@nl.example.com:443?type=xhttp&mode=auto&path=%2Fx&security=tls&sni=nl.example.com#NL",
                     "trojan://pw@t.example.com:443?type=ws&path=%2Fws&host=cdn.example.com&security=tls#T"]
        let data = try #require(XrayLink.config(links.enumerated().map { (port: 24200 + $0.offset, link: $0.element) }, interface: "en0"))
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("wp-xray-\(UUID().uuidString).json")
        try data.write(to: f); defer { try? FileManager.default.removeItem(at: f) }
        let r = runProcess(xr.path, ["run", "-test", "-c", f.path])
        #expect(r.code == 0, "xray -test failed: \(r.out)\(r.err)")
    }
}
