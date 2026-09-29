import Foundation

/// Starts the user's VPN client together with Waypoint, and (optionally) brings it back if it drops.
/// It only ever uses the client's public control surface: the system VPN service (`scutil --nc`) and launching the app.
public enum VPNLauncher {
    /// Known clients: the system service name → the bundle id of its app.
    public static let bundleIDs = ["Happ": "su.ffg.happ"]

    public enum Outcome: Equatable, Sendable { case alreadyUp, started, startedViaApp, failed(String) }

    /// Makes sure the VPN service is connected *and* its local proxy answers. Tries the system service first, then launches the app.
    public static func ensureRunning(settings s: AppSettings, timeout: TimeInterval = 45, log: @Sendable (String) -> Void = { _ in }) async -> Outcome {
        guard let name = s.vpnServiceName else { return .failed("не выбран системный VPN-сервис") }
        func up() async -> Bool {
            guard VPNController.isConnected(name) else { return false }
            return await UpstreamProbe.isOpenSocks5(host: s.upstreamHost, port: s.upstreamPort, timeoutMs: 800)
        }
        if await up() { return .alreadyUp }
        guard VPNController.service(named: name) != nil else { return .failed("сервис «\(name)» не найден в системе") }

        log("запускаю VPN «\(name)»…")
        VPNController.start(name)
        let deadline = Date().addingTimeInterval(timeout)
        let appDeadline = Date().addingTimeInterval(min(12, timeout / 2))
        var launchedApp = false
        while Date() < deadline {
            if await up() { return launchedApp ? .startedViaApp : .started }
            if !launchedApp, Date() > appDeadline, let bid = bundleIDs[name] {
                log("сервис не поднялся сам — открываю приложение")
                runProcess("/usr/bin/open", ["-g", "-b", bid])        // -g: do not steal focus
                launchedApp = true
                VPNController.start(name)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return .failed("не подключился за \(Int(timeout)) с")
    }
}
