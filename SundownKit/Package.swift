// swift-tools-version: 6.2
import Foundation
import PackageDescription

/// Local development: with a tether-server checkout beside this repo, the protocol package comes
/// from it, so a protocol change is seen on the next build with no release. `SUNDOWN_USE_RELEASE=1`,
/// or no sibling (a fresh clone, CI), uses the published package instead.
let siblingServer = Context.packageDirectory + "/../../tether-server"
let useSiblingServer = Context.environment["SUNDOWN_USE_RELEASE"] != "1"
    && FileManager.default.fileExists(atPath: siblingServer + "/Package.swift")

let package = Package(
    name: "SundownKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SundownKit", targets: ["SundownKit"]),
        .library(name: "SundownUI", targets: ["SundownUI"]),
    ],
    dependencies: [
        // Generated protocol types are published by the server repository as a Swift package.
        useSiblingServer
            ? .package(path: "../../tether-server")
            : .package(url: "https://github.com/AFRUITPIE/tether-server.git", from: "0.1.0"),
    ],
    targets: [
        .target(name: "SundownKit", dependencies: [.product(name: "TetherProtocol", package: "tether-server")]),
        .target(name: "SundownUI", dependencies: ["SundownKit"]),
        .testTarget(name: "SundownKitTests", dependencies: ["SundownKit"]),
        .testTarget(name: "SundownUITests", dependencies: [
            "SundownUI", "SundownKit", .product(name: "TetherProtocol", package: "tether-server"),
        ]),
    ]
)
