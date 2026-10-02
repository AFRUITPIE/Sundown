// swift-tools-version: 6.2
import Foundation
import PackageDescription

/// Local development: with a tether-server checkout beside this repo, the protocol package comes
/// from it, so a protocol change is seen on the next build with no release. `TETHER_USE_RELEASE=1`,
/// or no sibling (a fresh clone, CI), uses the published package instead.
let siblingServer = Context.packageDirectory + "/../../tether-server"
let useSiblingServer = Context.environment["TETHER_USE_RELEASE"] != "1"
    && FileManager.default.fileExists(atPath: siblingServer + "/Package.swift")

let package = Package(
    name: "TetherKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "TetherKit", targets: ["TetherKit"]),
        .library(name: "TetherUI", targets: ["TetherUI"]),
    ],
    dependencies: [
        // Generated protocol types are published by the server repository as a Swift package.
        useSiblingServer
            ? .package(path: "../../tether-server")
            : .package(url: "https://github.com/AFRUITPIE/tether-server.git", from: "0.1.0"),
    ],
    targets: [
        .target(name: "TetherKit", dependencies: [.product(name: "TetherProtocol", package: "tether-server")]),
        .target(name: "TetherUI", dependencies: ["TetherKit"]),
        .testTarget(name: "TetherKitTests", dependencies: ["TetherKit"]),
        .testTarget(name: "TetherUITests", dependencies: [
            "TetherUI", "TetherKit", .product(name: "TetherProtocol", package: "tether-server"),
        ]),
    ]
)
