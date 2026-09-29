import Foundation
import Network

// MARK: - AppSettings

public struct AppSettings: Codable, Equatable, Sendable {
    public var listenPort: UInt16 = 7810
    public var upstreamHost = "127.0.0.1"
    public var upstreamPort: UInt16 = 10808
    public var region: Region = .russia
    public var race = RaceConfigCodable()
    /// Name of the system VPN service (as in `scutil --nc list`) that Waypoint may start/stop.
    public var vpnServiceName: String? = "Happ"
    /// Start the VPN when something needs it and stop it after `idleDisconnectMinutes` without VPN traffic.
    public var onDemandVPN = false
    public var idleDisconnectMinutes = 10
    /// Tunnel mode tuning (optional so older settings.json files still decode). Validated against a whitelist by the daemon.
    public var tunnelStack: String?          // system | gvisor | mixed   (default gvisor)
    /// Explicit per-service choice: service id → "vpn" | "direct" | "block" ("auto" = no entry).
    public var servicePolicies: [String: String]?
    /// Ids of active scenarios (see `Playbook.all`).
    public var playbooks: [String]?
    public var autoStartVPN: Bool?           // start the VPN client together with Waypoint
    public var reconnectVPN: Bool?           // reconnect it if it drops
    public var communityLists: Bool?         // download and use community rule lists (opt-in)
    public var notifications: Bool?
    public var onboardingDone: Bool?
    public var tunnelUDPViaVPN: Bool?        // send unrecognised UDP (Discord voice, games) through the VPN
    public var tunnelLogLevel: String?       // trace | debug | info | warn | error  (default warn)

    public init() {}

    public struct RaceConfigCodable: Codable, Equatable, Sendable {
        public var hedgeMs = 900
        public var directDeadlineMs = 5000
        public var vpnDeadlineMs = 12000
        public init() {}
        var config: RaceConfig { RaceConfig(hedgeMs: hedgeMs, directDeadlineMs: directDeadlineMs, vpnDeadlineMs: vpnDeadlineMs) }
    }

    // MARK: persistence

    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WAYPOINT_HOME"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waypoint", isDirectory: true)
    }

    public static func load(from dir: URL = supportDirectory) -> AppSettings {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func save(to dir: URL = supportDirectory) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: dir.appendingPathComponent("settings.json"), options: .atomic) }
    }

    public var pacURL: String { "http://127.0.0.1:\(listenPort)/proxy.pac" }
}

// MARK: - Physical interface tracking

/// Tracks which physical interface (Wi‑Fi / Ethernet) direct connections must be pinned to.
/// Everything with type `.other` (utun, ipsec, ppp: i.e. VPNs) is deliberately excluded.
public final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _physical: NWInterface?
    private var _all: [NWInterface] = []
    public var onChange: (@Sendable (NWInterface?) -> Void)?

    public init() {}

    public var physical: NWInterface? { lock.lock(); defer { lock.unlock() }; return _physical }
    public var allInterfaces: [NWInterface] { lock.lock(); defer { lock.unlock() }; return _all }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let phys = path.availableInterfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }
            self.lock.lock()
            let changed = self._physical?.name != phys?.name
            self._physical = phys
            self._all = path.availableInterfaces
            self.lock.unlock()
            if changed { self.onChange?(phys) }
        }
        monitor.start(queue: DispatchQueue(label: "waypoint.netmon"))
    }

    public func stop() { monitor.cancel() }
}

// MARK: - System VPN services (Happ, WireGuard, IKEv2 …) via scutil

public struct VPNService: Equatable, Sendable {
    public let id: String
    public let name: String
    public let state: String       // Connected / Disconnected / Connecting / Disconnecting / Invalid
    public var isConnected: Bool { state == "Connected" }
}

public enum VPNController {
    private static let scutil = "/usr/sbin/scutil"

    public static func list() -> [VPNService] {
        let r = runProcess(scutil, ["--nc", "list"])
        guard r.code == 0 else { return [] }
        let re = try! NSRegularExpression(pattern: #"\((Connected|Disconnected|Connecting|Disconnecting|Invalid)\)\s+([0-9A-Fa-f-]{36}).*?"(.+?)""#)
        return r.out.split(separator: "\n").compactMap { line in
            let s = String(line)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 4,
                  let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s), let c = Range(m.range(at: 3), in: s)
            else { return nil }
            return VPNService(id: String(s[b]), name: String(s[c]), state: String(s[a]))
        }
    }

    public static func service(named name: String) -> VPNService? { list().first { $0.name == name } }

    public static func isConnected(_ name: String) -> Bool { service(named: name)?.isConnected ?? false }

    @discardableResult public static func start(_ name: String) -> Bool { runProcess(scutil, ["--nc", "start", name]).code == 0 }
    @discardableResult public static func stop(_ name: String) -> Bool { runProcess(scutil, ["--nc", "stop", name]).code == 0 }

    /// Starts the VPN (if needed) and waits until `probe` says its local proxy is reachable.
    public static func ensureConnected(_ name: String, timeoutSeconds: Double = 15, probe: @Sendable () async -> Bool) async -> Bool {
        if !isConnected(name) { start(name) }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isConnected(name), await probe() { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }
}

// MARK: - Upstream discovery

public enum UpstreamProbe {
    /// True if `host:port` speaks SOCKS5 without authentication.
    public static func isOpenSocks5(host: String, port: UInt16, timeoutMs: Int = 1500) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        defer { conn.cancel() }
        return (try? await withTimeout(ms: timeoutMs) {
            try await conn.awaitReady()
            try await conn.sendAsync(Data([0x05, 0x01, 0x00]))
            let (d, _) = try await conn.receiveAsync(min: 2, max: 2)
            return d.count == 2 && d[d.startIndex] == 0x05 && d[d.startIndex + 1] == 0x00
        }) ?? false
    }

    /// Ports commonly used by local SOCKS5 inbounds (Xray/Happ, v2rayN, Clash, sing-box, Shadowsocks…).
    public static let commonPorts: [UInt16] = [10808, 1080, 7891, 7890, 2080, 20170, 1086, 10086, 7897, 9910]

    public static func detect(host: String = "127.0.0.1") async -> UInt16? {
        for p in commonPorts where await isOpenSocks5(host: host, port: p, timeoutMs: 700) { return p }
        return nil
    }
}

// MARK: - PAC

public enum PAC {
    /// Everything except LAN goes to Waypoint. Waypoint (not the PAC) picks direct vs VPN, because a PAC
    /// "DIRECT" would follow the default route — i.e. straight into the VPN tunnel when it is a full tunnel.
    /// `DIRECT` at the end is the fail-safe: if Waypoint is not running the network keeps working.
    public static func script(port: UInt16) -> String {
        """
        function FindProxyForURL(url, host) {
          var proxy = "SOCKS5 127.0.0.1:\(port); SOCKS 127.0.0.1:\(port); PROXY 127.0.0.1:\(port); DIRECT";
          // IPv6 literals contain no dots, so isPlainHostName() would call them "plain" — test them first.
          if (host.indexOf(":") !== -1) return /^(::1|fe80|fc|fd)/i.test(host) ? "DIRECT" : proxy;
          if (isPlainHostName(host) || host === "localhost" ||
              shExpMatch(host, "*.local") || shExpMatch(host, "*.lan") || shExpMatch(host, "*.home.arpa")) return "DIRECT";
          var m = /^(\\d{1,3})\\.(\\d{1,3})\\.\\d{1,3}\\.\\d{1,3}$/.exec(host);
          if (m) {
            var a = +m[1], b = +m[2];
            if (a === 127 || a === 10 || a === 0 || (a === 172 && b >= 16 && b <= 31) ||
                (a === 192 && b === 168) || (a === 169 && b === 254) || (a === 100 && b >= 64 && b <= 127)) return "DIRECT";
          }
          return proxy;
        }
        """
    }
}

// MARK: - Applying the PAC to macOS network services

public enum SystemProxy {
    private static let networksetup = "/usr/sbin/networksetup"

    struct Backup: Codable { var services: [String: Entry] }
    struct Entry: Codable { var enabled: Bool; var url: String }

    private static var backupURL: URL { AppSettings.supportDirectory.appendingPathComponent("proxy-backup.json") }

    /// Every service that exists and is enabled — including the VPN's own service, because when a full-tunnel VPN
    /// is primary, macOS takes proxy settings from *its* service, not from Wi‑Fi.
    public static func services() -> [String] {
        let r = runProcess(networksetup, ["-listallnetworkservices"])
        return r.out.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    static func currentPAC(_ service: String) -> Entry {
        let r = runProcess(networksetup, ["-getautoproxyurl", service])
        var url = "", enabled = false
        for line in r.out.split(separator: "\n") {
            if line.hasPrefix("URL:") { url = line.dropFirst(4).trimmingCharacters(in: .whitespaces); if url == "(null)" { url = "" } }
            if line.hasPrefix("Enabled:") { enabled = line.contains("Yes") }
        }
        return Entry(enabled: enabled, url: url)
    }

    /// What macOS currently uses as the effective (global) auto-proxy URL.
    public static func effectivePACURL() -> String? {
        let r = runProcess("/usr/sbin/scutil", ["--proxy"])
        for line in r.out.split(separator: "\n") where line.contains("ProxyAutoConfigURLString") {
            return line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    public static func isApplied(_ pacURL: String) -> Bool { effectivePACURL() == pacURL }

    public enum Status: Equatable {
        case off
        /// Global (unscoped) proxy settings point at our PAC: applications really use it.
        case active
        /// Written for a specific interface only. Happens while a full-tunnel VPN (NE service such as Happ) is the
        /// primary service: macOS takes global proxies from *it* and ignores what we wrote, so apps do not use the PAC.
        case ignoredByVPN
    }

    public static func status(_ pacURL: String) -> Status {
        if isApplied(pacURL) { return .active }
        let written = services().contains { let e = currentPAC($0); return e.enabled && e.url == pacURL }
        return written ? .ignoredByVPN : .off
    }

    public static func apply(pacURL: String, allowPrompt: Bool = true) throws {
        let svcs = services()
        var backup = (try? JSONDecoder().decode(Backup.self, from: Data(contentsOf: backupURL))) ?? Backup(services: [:])
        for s in svcs where backup.services[s] == nil {
            let cur = currentPAC(s)
            // Never "back up" our own PAC as the user's original setting.
            backup.services[s] = cur.url == pacURL ? Entry(enabled: false, url: "") : cur
        }
        try? FileManager.default.createDirectory(at: AppSettings.supportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(backup).write(to: backupURL, options: .atomic)
        try runNetworksetup(svcs.flatMap { [["-setautoproxyurl", $0, pacURL], ["-setautoproxystate", $0, "on"]] }, allowPrompt: allowPrompt)
    }

    public static func restore(allowPrompt: Bool = true) throws {
        guard let data = try? Data(contentsOf: backupURL), let backup = try? JSONDecoder().decode(Backup.self, from: data) else {
            // No backup: just make sure our PAC is off everywhere.
            try runNetworksetup(services().map { ["-setautoproxystate", $0, "off"] }, allowPrompt: allowPrompt)
            return
        }
        let existing = Set(services())
        var cmds: [[String]] = []
        for (s, e) in backup.services where existing.contains(s) {
            if !e.url.isEmpty { cmds.append(["-setautoproxyurl", s, e.url]) }
            cmds.append(["-setautoproxystate", s, e.enabled && !e.url.isEmpty ? "on" : "off"])
        }
        try runNetworksetup(cmds, allowPrompt: allowPrompt)
        try? FileManager.default.removeItem(at: backupURL)
    }

    /// Tries unprivileged first; if macOS refuses, asks for admin rights once (native password / Touch ID dialog).
    private static func runNetworksetup(_ commands: [[String]], allowPrompt: Bool) throws {
        guard !commands.isEmpty else { return }
        var failed = false
        for c in commands {
            let r = runProcess(networksetup, c)
            if r.code != 0 || r.out.contains("requires") || r.err.contains("permission") { failed = true; break }
        }
        if !failed { return }
        guard allowPrompt else { throw UpstreamError("Нужны права администратора") }
        let script = commands.map { "/usr/sbin/networksetup " + $0.map(shellQuote).joined(separator: " ") }.joined(separator: "; ")
        let apple = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let r = runProcess("/usr/bin/osascript", ["-e", apple])
        if r.code != 0 { throw UpstreamError("Не удалось изменить сетевые настройки: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
