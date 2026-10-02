import Testing
import Foundation
@testable import WaypointCore

@Suite("Server health") struct ServerHealthTests {
    func entry(_ id: String, enabled: Bool = true, works: Bool? = true, checked: Bool = true, fails: Int? = nil, autoOff: Bool? = nil) -> ServerEntry {
        var e = ServerEntry(id: id, name: id, link: "x", enabled: enabled)
        e.works = works; e.checked = checked ? Date(timeIntervalSince1970: 1) : nil; e.fails = fails; e.autoOff = autoOff
        return e
    }
    func res(_ id: String, ok: Bool, country: String? = "DE", engine: String? = "sing-box") -> ServerAudit.Result {
        ServerAudit.Result(id: id, name: id, ok: ok, ms: ok ? 100 : nil, country: ok ? country : nil, error: ok ? nil : "x", engine: ok ? engine : nil)
    }

    @Test func oneFailureNeverSwitchesAWorkingServerOff() {
        var l = [entry("a"), entry("b"), entry("c"), entry("d")]
        let s = ServerHealth.apply([res("a", ok: false), res("b", ok: true), res("c", ok: true), res("d", ok: true)], to: &l, russia: false)
        #expect(l[0].enabled && l[0].works == true && l[0].fails == 1 && s.switchedOff.isEmpty)
    }

    @Test func twoFailuresInARowSwitchItOffAndFlagItForRecovery() {
        var l = [entry("a"), entry("b"), entry("c"), entry("d")]
        for _ in 0..<2 { ServerHealth.apply([res("a", ok: false), res("b", ok: true), res("c", ok: true), res("d", ok: true)], to: &l, russia: false) }
        #expect(!l[0].enabled && l[0].works == false && l[0].autoOff == true)
        #expect(ServerHealth.needsRecheck(l).map(\.id) == ["a"])
    }

    @Test func aSwitchedOffServerComesBackWhenItWorksAgain() {
        var l = [entry("a", enabled: false, works: false, fails: 2, autoOff: true), entry("b"), entry("c"), entry("d")]
        let s = ServerHealth.apply([res("a", ok: true), res("b", ok: true), res("c", ok: true), res("d", ok: true)], to: &l, russia: false)
        #expect(l[0].enabled && l[0].works == true && l[0].fails == nil && l[0].autoOff == nil && s.recovered == ["a"])
    }

    @Test func aServerTheUserSwitchedOffStaysOff() {
        var l = [entry("a", enabled: false, works: true), entry("b")]
        ServerHealth.apply([res("a", ok: true), res("b", ok: true)], to: &l, russia: false)
        #expect(!l[0].enabled)
        #expect(ServerHealth.needsRecheck(l).isEmpty)
    }

    @Test func entriesFromBeforeTheFlagExistedAreRecognisedAsCheckerOff() {
        let old = entry("a", enabled: false, works: false)
        #expect(ServerHealth.isAutoOff(old))
        var l = [old, entry("b")]
        ServerHealth.apply([res("a", ok: true), res("b", ok: true)], to: &l, russia: false)
        #expect(l[0].enabled)
    }

    @Test func aRunWhereMostServersFailIsTreatedAsANetworkProblemAndChangesNothing() {
        var l = (0..<10).map { entry("s\($0)") }
        let before = l
        let results = l.enumerated().map { res($0.element.id, ok: $0.offset < 2) }       // 8 of 10 failed
        let s = ServerHealth.apply(results, to: &l, russia: false)
        #expect(s.ignoredAsNetworkProblem && l == before)
    }

    @Test func aNeverCheckedServerThatFailsIsOffAtOnceButStaysRecoverable() {
        var l = [entry("a", enabled: true, works: nil, checked: false), entry("b"), entry("c"), entry("d")]
        ServerHealth.apply([res("a", ok: false), res("b", ok: true), res("c", ok: true), res("d", ok: true)], to: &l, russia: false)
        #expect(!l[0].enabled && l[0].autoOff == true && ServerHealth.needsRecheck(l).map(\.id) == ["a"])
    }

    @Test func firstSuccessfulCheckEnablesExceptRussianExitsInTheRussianRegion() {
        var l = [entry("a", enabled: true, works: nil, checked: false), entry("ru", enabled: true, works: nil, checked: false)]
        ServerHealth.apply([res("a", ok: true), res("ru", ok: true, country: "RU")], to: &l, russia: true)
        #expect(l[0].enabled && !l[1].enabled)
    }

    @Test func engineFollowsTheCheck() {
        var l = [entry("a")]
        ServerHealth.apply([res("a", ok: true, engine: "xray")], to: &l, russia: false)
        #expect(l[0].engine == "xray")
        ServerHealth.apply([res("a", ok: true, engine: "sing-box")], to: &l, russia: false)
        #expect(l[0].engine == nil)
    }
}
