import Foundation

/// What to do with the user's servers after a check. Measurements are noisy (a busy network, a server restarting,
/// a provider rotating an address): one bad result must not take a working server out of the pools for good, and a bad
/// run caused by our own network must not change anything.
public enum ServerHealth {
    /// Consecutive failed checks before a server that used to work is switched off.
    public static let offAfter = 2
    /// If at least this share of a big enough run fails, the problem is the network, not the servers: ignore the run.
    static let networkSuspectShare = 0.7
    static let networkSuspectMinimum = 4

    public struct Summary: Equatable, Sendable {
        public var ok = 0, total = 0
        public var switchedOff: [String] = []
        public var recovered: [String] = []
        /// Most servers failed at once: nothing was changed.
        public var ignoredAsNetworkProblem = false
    }

    /// Off because the checker said so (as opposed to the user's own toggle). Entries from before this field existed:
    /// only a check ever sets `works = false`, so «failed and off» means the checker did it.
    public static func isAutoOff(_ s: ServerEntry) -> Bool { s.autoOff == true || (s.works == false && !s.enabled) }

    /// Servers worth checking again soon: switched off by the checker, failing, or with a recent failure.
    public static func needsRecheck(_ list: [ServerEntry]) -> [ServerEntry] {
        list.filter { isAutoOff($0) || ($0.fails ?? 0) > 0 || $0.works == false }
    }

    @discardableResult
    public static func apply(_ results: [ServerAudit.Result], to servers: inout [ServerEntry], russia: Bool, now: Date = Date()) -> Summary {
        var sum = Summary(); sum.total = results.count; sum.ok = results.filter(\.ok).count
        let failed = results.count - sum.ok
        if results.count >= networkSuspectMinimum, Double(failed) >= Double(results.count) * networkSuspectShare {
            sum.ignoredAsNetworkProblem = true
            return sum
        }
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        for i in servers.indices {
            guard let r = byID[servers[i].id] else { continue }
            let wasChecked = servers[i].checked != nil
            let wasAutoOff = isAutoOff(servers[i])          // before the fields below are overwritten
            servers[i].checked = now
            if r.ok {
                servers[i].works = true; servers[i].ms = r.ms; servers[i].fails = nil
                if let c = r.country { servers[i].exit = c }
                servers[i].engine = r.engine == "xray" ? "xray" : nil
                let russian = russia && r.country == "RU"
                if !wasChecked { servers[i].enabled = !russian }
                else if wasAutoOff && !russian { servers[i].enabled = true; sum.recovered.append(servers[i].name) }
                servers[i].autoOff = nil
            } else {
                servers[i].ms = nil
                let n = (servers[i].fails ?? 0) + 1
                servers[i].fails = n
                // A server never seen working is off right away (it was re-tried within the run); one that worked needs repeated failures.
                if !wasChecked || servers[i].works != true || n >= offAfter {
                    servers[i].works = false
                    if servers[i].enabled { servers[i].enabled = false; servers[i].autoOff = true; sum.switchedOff.append(servers[i].name) }
                }
            }
        }
        return sum
    }
}
