import Testing
import Foundation
import JavaScriptCore
@testable import WaypointCore

@Suite("PAC") struct PACTests {
    func evaluator(port: UInt16 = 7810) -> (String, String) -> String {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        function isPlainHostName(h){ return h.indexOf('.') < 0; }
        function shExpMatch(s,p){ return new RegExp('^'+p.replace(/[.+^${}()|[\\]\\\\]/g,'\\\\$&').replace(/\\*/g,'.*').replace(/\\?/g,'.')+'$').test(s); }
        """)
        ctx.evaluateScript(PAC.script(port: port))
        let f = ctx.objectForKeyedSubscript("FindProxyForURL")!
        return { url, host in f.call(withArguments: [url, host])!.toString() }
    }

    @Test func lanStaysDirectEverythingElseGoesToWaypoint() {
        let find = evaluator()
        for h in ["localhost", "printer", "nas.local", "127.0.0.1", "10.0.0.7", "172.16.5.5", "172.31.255.1", "192.168.31.1", "169.254.9.9", "100.64.1.1", "::1", "fe80::abcd"] {
            #expect(find("https://\(h)/", h) == "DIRECT", "\(h)")
        }
        for h in ["youtube.com", "8.8.8.8", "172.32.0.1", "yandex.ru", "2001:db8::1"] {
            #expect(find("https://\(h)/", h) == "SOCKS5 127.0.0.1:7810; SOCKS 127.0.0.1:7810; PROXY 127.0.0.1:7810; DIRECT", "\(h)")
        }
    }

    @Test func portIsParameterised() {
        #expect(evaluator(port: 9999)("http://a.com/", "a.com").contains("127.0.0.1:9999"))
    }
}

@Suite("Protocol details") struct ProtocolTests {
    @Test func socks5ConnectRequests() {
        #expect([UInt8](Socks5.connectRequest(host: "a.io", port: 443)) == [5, 1, 0, 3, 4] + Array("a.io".utf8) + [0x01, 0xBB])
        #expect([UInt8](Socks5.connectRequest(host: "1.2.3.4", port: 80)) == [5, 1, 0, 1, 1, 2, 3, 4, 0, 80])
        let v6 = [UInt8](Socks5.connectRequest(host: "::1", port: 8443))
        #expect(v6.count == 4 + 16 + 2 && v6[3] == 4 && v6[19] == 1)
    }

    @Test func firstResponseValidation() throws {
        // TLS
        try FirstResponse.validate(Data([0x16, 0x03, 0x03, 0x00, 0x7a]), port: 443)              // ServerHello
        try FirstResponse.validate(Data([0x15, 0x03, 0x03, 0x00, 0x02, 2, 40]), port: 443)       // alert: a real server answered
        #expect(throws: BadFirstResponse.self) { try FirstResponse.validate(Data("HTTP/1.1 200 OK".utf8), port: 443) }
        #expect(throws: BadFirstResponse.self) { try FirstResponse.validate(Data(), port: 443) }
        // HTTP
        try FirstResponse.validate(Data("HTTP/1.1 200 OK\r\n\r\n".utf8), port: 80)
        #expect(throws: BadFirstResponse.self) { try FirstResponse.validate(Data([0x16, 0x03, 0x03]), port: 80) }
        let stub = "HTTP/1.1 302 Found\r\nLocation: http://warning.rt.ru/?id=1\r\n\r\n"
        #expect(throws: BadFirstResponse.self) { try FirstResponse.validate(Data(stub.utf8), port: 80) }
        let ok = "HTTP/1.1 301 Moved\r\nLocation: https://blockchain.com/\r\n\r\n"     // "block" inside a name is fine
        try FirstResponse.validate(Data(ok.utf8), port: 80)
        // other ports: anything non-empty
        try FirstResponse.validate(Data([1, 2, 3]), port: 22)
    }

    @Test func hostPortSplitting() {
        #expect(ClientSession.splitHostPort("example.com:8443", defaultPort: 443)! == ("example.com", 8443))
        #expect(ClientSession.splitHostPort("example.com", defaultPort: 443)! == ("example.com", 443))
        #expect(ClientSession.splitHostPort("[2001:db8::1]:444", defaultPort: 443)! == ("2001:db8::1", 444))
        #expect(ClientSession.splitHostPort("::1", defaultPort: 443) == nil)
    }

    @Test func httpBodyPlans() {
        func plan(_ h: String) -> HTTPBodyPlan { HTTPBodyPlan.parse(head: Data((h + "\r\n\r\n").utf8)) }
        #expect(plan("GET / HTTP/1.1\r\nHost: a") == .none)
        #expect(plan("POST /x HTTP/1.1\r\nHost: a\r\nContent-Length: 22") == .fixed(22))
        #expect(plan("POST /x HTTP/1.1\r\ncontent-length: 0") == .none)
        #expect(plan("POST /x HTTP/1.1\r\nContent-Length: 999999999") == .unsuitable)
        #expect(plan("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked") == .unsuitable)
        #expect(plan("PUT /x HTTP/1.1\r\nContent-Length: 10\r\nExpect: 100-continue") == .unsuitable)
    }

    @Test func happProfile() throws {
        let e = RuleEngine(directory: nil, region: .none)
        e.noteDirectBlocked(host: "x.blocked.example"); e.noteDirectBlocked(host: "blocked.example")
        e.noteDirectBlocked(host: "149.154.167.51"); e.noteDirectBlocked(host: "149.154.167.52")
        e.setManualRules([.init(route: .direct, kind: .suffix, value: "bank.ru"), .init(route: .vpn, kind: .keyword, value: "tiktok")], persist: false)
        let l = HappRouting.lists(rules: e, region: .none)
        #expect(l.proxySites.contains("domain:blocked.example") && l.proxySites.contains("keyword:tiktok"))
        #expect(l.proxyIP == ["149.154.167.0/24"])
        #expect(l.directSites == ["domain:bank.ru"])
        let json = try JSONSerialization.jsonObject(with: HappRouting.profileJSON(l)) as! [String: Any]
        #expect(json["GlobalProxy"] as? String == "false" && json["Name"] as? String == "Waypoint")
        let url = HappRouting.deeplink(HappRouting.profileJSON(l), activate: false)!
        #expect(url.absoluteString.hasPrefix("happ://routing/add/"))
        let b64 = String(url.absoluteString.dropFirst("happ://routing/add/".count))
        #expect(Data(base64Encoded: b64) != nil)
        #expect(HappRouting.deeplink(Data(), activate: true)!.absoluteString.hasPrefix("happ://routing/onadd/"))
    }

    /// Builds a syntactically valid ClientHello with the given server_name (and an unrelated extension before it).
    func clientHello(sni: String?) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
        var ext: [UInt8] = u16(0x0010) + u16(5) + [0, 3, 2, 104, 50]                        // ALPN-ish filler
        if let sni {
            let n = Array(sni.utf8)
            let list = [UInt8(0)] + u16(n.count) + n
            ext += u16(0) + u16(list.count + 2) + u16(list.count) + list
        }
        var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 7, count: 32) + [0] + u16(2) + [0x13, 0x01] + [1, 0] + u16(ext.count) + ext
        body = [0x01, UInt8(body.count >> 16), UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff)] + body
        return Data([0x16, 0x03, 0x01] + u16(body.count) + body)
    }

    @Test func sniffsServerNameFromClientHello() {
        #expect(Sniff.tlsServerName(clientHello(sni: "Rutracker.org")) == "rutracker.org")
        #expect(Sniff.tlsServerName(clientHello(sni: nil)) == nil)
        #expect(Sniff.tlsServerName(clientHello(sni: "bad host\"x.com")) == nil)            // never trust odd bytes
        #expect(Sniff.tlsServerName(Data([0x16, 0x03, 0x01])) == nil)                      // truncated
        #expect(Sniff.tlsServerName(Data("GET / HTTP/1.1\r\n\r\n".utf8)) == nil)
    }

    @Test func sniffsHTTPHost() {
        #expect(Sniff.httpHost(Data("GET / HTTP/1.1\r\nHost: Example.com:8080\r\n\r\n".utf8)) == "example.com")
        #expect(Sniff.httpHost(Data("GET / HTTP/1.1\r\nHost: 1.2.3.4\r\n\r\n".utf8)) == nil)
        #expect(Sniff.httpHost(Data("GET / HTTP/1.1\r\n\r\n".utf8)) == nil)
    }
}
