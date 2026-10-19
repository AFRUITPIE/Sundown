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
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SundownKit", targets: ["SundownKit"]),
        .library(name: "SundownUI", targets: ["SundownUI"]),
    ],
    dependencies: [
        // Generated protocol types are published by the server repository as a Swift package.
        useSiblingServer
            ? .package(path: "../../tether-server")
            : .package(url: "https://github.com/AFRUITPIE/tether-server.git", from: "0.1.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
        // Messages' Markdown: CommonMark and GitHub's extensions, parsed by cmark-gfm.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .target(name: "SundownKit", dependencies: [
            .product(name: "TetherProtocol", package: "tether-server"),
            .product(name: "Subprocess", package: "swift-subprocess"),
        ]),
        // A daemon in memory (`FakeHost`) and the chats it serves: the UI-test fixture, which every
        // build carries (the performance tests run against Release), previews' samples, and the
        // tests' fake host.
        .target(name: "SundownFixtures", dependencies: [
            "SundownKit", .product(name: "TetherProtocol", package: "tether-server"),
        ]),
        .target(name: "SundownUI", dependencies: [
            "SundownKit", "SundownFixtures", .product(name: "Markdown", package: "swift-markdown"),
        ]),
        // What both test targets share: waiting, observing, building items. Tests only.
        .target(name: "SundownTestSupport", dependencies: [
            "SundownKit", "SundownFixtures", .product(name: "TetherProtocol", package: "tether-server"),
        ]),
        .testTarget(name: "SundownKitTests", dependencies: ["SundownKit", "SundownFixtures", "SundownTestSupport"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SundownUITests", dependencies: [
            "SundownUI", "SundownKit", "SundownFixtures", "SundownTestSupport",
            .product(name: "TetherProtocol", package: "tether-server"),
        ]),
    ]
)
