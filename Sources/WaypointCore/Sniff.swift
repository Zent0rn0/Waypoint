import Foundation

/// Names recovered from a client's first flight. In tunnel mode the racer is handed bare IP addresses (the system
/// resolver is interface-scoped and never enters the TUN), so the server name is read from the traffic itself.
enum Sniff {
    /// server_name from a TLS ClientHello record, or nil.
    static func tlsServerName(_ d: Data) -> String? {
        let b = [UInt8](d)
        var i = 0
        func u8() -> Int? { guard i < b.count else { return nil }; defer { i += 1 }; return Int(b[i]) }
        func u16() -> Int? { guard let a = u8(), let c = u8() else { return nil }; return a << 8 | c }
        guard u8() == 0x16, u16() != nil, u16() != nil else { return nil }          // record: handshake, version, length
        guard u8() == 0x01 else { return nil }                                        // ClientHello
        i += 3 + 2 + 32                                                               // length(3) version(2) random(32)
        guard let sidLen = u8() else { return nil }; i += sidLen
        guard let csLen = u16() else { return nil }; i += csLen
        guard let compLen = u8() else { return nil }; i += compLen
        guard let extTotal = u16() else { return nil }
        let end = min(b.count, i + extTotal)
        while i + 4 <= end {
            guard let type = u16(), let len = u16() else { return nil }
            if type == 0 {                                                            // server_name
                guard u16() != nil, u8() == 0, let nameLen = u16(), i + nameLen <= b.count else { return nil }
                let name = String(decoding: b[i..<(i + nameLen)], as: UTF8.self).lowercased()
                return TunnelConfig.isValidHostname(name) ? name : nil
            }
            i += len
        }
        return nil
    }

    /// Host header of a plain HTTP request head, without port.
    static func httpHost(_ d: Data) -> String? {
        let text = String(decoding: d.prefix(4096), as: UTF8.self)
        for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("host:") {
            var v = line.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
            if let c = v.lastIndex(of: ":"), !v.hasPrefix("[") { v = String(v[..<c]) }
            return TunnelConfig.isValidHostname(v) && !isIPLiteral(v) ? v : nil
        }
        return nil
    }
}
