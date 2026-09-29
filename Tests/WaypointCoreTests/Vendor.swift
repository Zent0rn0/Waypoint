import Foundation

/// The helper engines are downloaded by `scripts/fetch-vendor.sh` and are not part of the repository.
/// Tests that need the real binaries are skipped (not failed) on a fresh checkout.
enum Vendor {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var hasSingBox: Bool { FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("vendor/sing-box").path) }
    static var hasXray: Bool { FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("vendor/xray").path) }
}
