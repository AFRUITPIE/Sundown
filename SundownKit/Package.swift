// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SundownKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TetherProtocol", targets: ["TetherProtocol"]),
        .library(name: "SundownKit", targets: ["SundownKit"]),
        .library(name: "SundownUI", targets: ["SundownUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
        // Messages' Markdown: CommonMark and GitHub's extensions, parsed by cmark-gfm.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        // Protocol types generated from server/src/protocol (`mise run gen` in server/).
        .target(name: "TetherProtocol"),
        .target(name: "SundownKit", dependencies: [
            "TetherProtocol",
            .product(name: "Subprocess", package: "swift-subprocess"),
        ]),
        // A daemon in memory (`FakeHost`) and the chats it serves: the UI-test fixture, which every
        // build carries (the performance tests run against Release), previews' samples, and the
        // tests' fake host.
        .target(name: "SundownFixtures", dependencies: [
            "SundownKit", "TetherProtocol",
        ]),
        .target(name: "SundownUI", dependencies: [
            "SundownKit", "SundownFixtures", "TetherProtocol", .product(name: "Markdown", package: "swift-markdown"),
        ]),
        // What both test targets share: waiting, observing, building items. Tests only.
        .target(name: "SundownTestSupport", dependencies: [
            "SundownKit", "SundownFixtures", "TetherProtocol",
        ]),
        .testTarget(name: "TetherProtocolTests", dependencies: ["TetherProtocol"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SundownKitTests", dependencies: ["SundownKit", "SundownFixtures", "SundownTestSupport", "TetherProtocol"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SundownUITests", dependencies: [
            "SundownUI", "SundownKit", "SundownFixtures", "SundownTestSupport",
            "TetherProtocol",
        ]),
    ]
)
