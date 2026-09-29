import Foundation
import SystemConfiguration

// MARK: - Discovering the interfaces / DNS the config needs

public enum NetworkFacts {
    /// utun interface of a connected system VPN service (Happ), read from the dynamic store.
    public static func vpnInterface(serviceID: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "waypoint" as CFString, nil, nil),
              let v = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv4" as CFString) as? [String: Any],
              let name = v["InterfaceName"] as? String, TunnelConfig.isValidInterface(name) else { return nil }
        return name
    }

    /// The resolver DHCP gave the physical interface (from the "scoped queries" part of `scutil --dns`).
    public static func directDNS(interface: String, fallback: String = "77.88.8.8") -> String {
        let out = runProcess("/usr/sbin/scutil", ["--dns"]).out
        guard let scoped = out.range(of: "for scoped queries") else { return fallback }
        var current: [String] = []
        var found: String?
        func flush() {
            let block = current.joined(separator: "\n")
            if found == nil, block.contains("(\(interface))"),
               let line = current.first(where: { $0.contains("nameserver[0]") }),
               let ip = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), ipv4Value(ip) != nil { found = ip }
            current = []
        }
        for line in out[scoped.upperBound...].split(separator: "\n") {
            if line.hasPrefix("resolver #") { flush() } else { current.append(String(line)) }
        }
        flush()
        return found ?? fallback
    }
}
