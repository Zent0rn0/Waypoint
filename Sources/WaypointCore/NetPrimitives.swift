import Foundation
import Network

// MARK: - Errors

struct TimeoutError: Error, CustomStringConvertible { var description: String { "timeout" } }
struct EOFError: Error, CustomStringConvertible { var description: String { "connection closed" } }
struct BadFirstResponse: Error, CustomStringConvertible {
    let reason: String
    var description: String { "implausible first response (\(reason))" }
}
struct UpstreamError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Small concurrency helpers

/// Guards a continuation against being resumed twice (NWConnection state handlers can fire repeatedly).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

/// Runs `op`, cancelling it (and therefore any NWConnection it is waiting on) after `ms` milliseconds.
func withTimeout<T: Sendable>(ms: Int, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(ms, 1)) * 1_000_000)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}

// MARK: - async/await over NWConnection

extension NWConnection {
    /// Starts the connection and suspends until it is ready (for TLS connections: handshake finished).
    /// `.waiting` is treated as failure: for a routing decision "can't reach it right now" is an answer.
    func awaitReady(queue: DispatchQueue = .global(qos: .userInitiated)) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = Once()
                self.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { cont.resume() }
                    case .failed(let e), .waiting(let e):
                        if once.claim() { cont.resume(throwing: e) }
                    case .cancelled:
                        if once.claim() { cont.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                self.start(queue: queue)
            }
        } onCancel: {
            self.cancel()
        }
    }

    func sendAsync(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.send(content: data, completion: .contentProcessed { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                })
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Half-close: sends FIN but keeps the receive side open.
    func sendFIN() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in cont.resume() })
        }
    }

    /// Returns (data, eof). `eof == true` only when the peer closed and there is no more data.
    func receiveAsync(min: Int = 1, max: Int = 64 * 1024) async throws -> (data: Data, eof: Bool) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(data: Data, eof: Bool), Error>) in
                self.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, isComplete, err in
                    if let err { cont.resume(throwing: err); return }
                    let d = data ?? Data()
                    cont.resume(returning: (d, isComplete && d.isEmpty))
                }
            }
        } onCancel: {
            self.cancel()
        }
    }
}

// MARK: - Buffered reader (parsers need "read exactly N" / "read until CRLFCRLF")

final class BufferedReader {
    let conn: NWConnection
    private(set) var buffer = Data()

    init(_ conn: NWConnection) { self.conn = conn }

    private func fill() async throws {
        let (d, eof) = try await conn.receiveAsync()
        if eof { throw EOFError() }
        buffer.append(d)
    }

    func peek(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        return Data(buffer.prefix(n))
    }

    func readExactly(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let out = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return out
    }

    /// Reads until `delimiter` (inclusive). Throws if `max` bytes pass without finding it.
    func readUntil(_ delimiter: Data, max: Int) async throws -> Data {
        while true {
            if let r = buffer.range(of: delimiter) {
                let out = Data(buffer.prefix(upTo: r.upperBound))
                buffer = Data(buffer.suffix(from: r.upperBound))
                return out
            }
            if buffer.count > max { throw BadFirstResponse(reason: "header too large") }
            try await fill()
        }
    }

    /// Whatever is buffered, or one more read if nothing is.
    func readSome() async throws -> Data {
        if buffer.isEmpty { try await fill() }
        let out = buffer
        buffer = Data()
        return out
    }

    /// Puts bytes back in front of the buffer (used to hand the reader everything the client already sent).
    func unread(_ data: Data) { buffer = data + buffer }

    func takeBuffered() -> Data {
        let out = buffer
        buffer = Data()
        return out
    }
}

// MARK: - Process helper (short-lived system tools: networksetup, scutil, osascript)

struct ProcessResult {
    let code: Int32
    let out: String
    let err: String
}

@discardableResult
func runProcess(_ path: String, _ args: [String]) -> ProcessResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    do { try p.run() } catch { return ProcessResult(code: -1, out: "", err: "\(error)") }
    let outData = o.fileHandleForReading.readDataToEndOfFile()
    let errData = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return ProcessResult(code: p.terminationStatus,
                         out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errData, as: UTF8.self))
}


/// For the app target: run a short system tool and get (exit code, stdout, stderr).
public func runProcessPublic(_ path: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
    let r = runProcess(path, args)
    return (r.code, r.out, r.err)
}
