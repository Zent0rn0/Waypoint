// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode: Network.framework callbacks + heavy use of continuations
// make strict Swift 6 sendability checking noisy without adding safety here.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Waypoint",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WaypointCore", targets: ["WaypointCore"]),
        .executable(name: "waypoint", targets: ["waypoint"]),
        .executable(name: "WaypointApp", targets: ["WaypointApp"]),
    ],
    targets: [
        .target(name: "WaypointCore", swiftSettings: v5),
        .executableTarget(name: "waypoint", dependencies: ["WaypointCore"], swiftSettings: v5),
        .executableTarget(name: "WaypointApp", dependencies: ["WaypointCore"], swiftSettings: v5),
        .testTarget(name: "WaypointCoreTests", dependencies: ["WaypointCore"], swiftSettings: v5),
    ]
)
