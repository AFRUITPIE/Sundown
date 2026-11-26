// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SundownKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SundownKit", targets: ["SundownKit"]),
        .library(name: "SundownUI", targets: ["SundownUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
        // Messages' Markdown: CommonMark and GitHub's extensions, parsed by cmark-gfm.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        // The server's protocol as Swift: `Generated.swift` is written by `mise run gen` in Server/
        // from its Zod, never by hand; `Support.swift` is the hand-written rest.
        .target(name: "ServerProtocol"),
        // Decodes wire traffic recorded from the real server (`Server/scripts/e2e.ts`).
        .testTarget(name: "ServerProtocolTests", dependencies: ["ServerProtocol"], resources: [.copy("Fixtures")]),
        .target(name: "SundownKit", dependencies: [
            "ServerProtocol",
            .product(name: "Subprocess", package: "swift-subprocess"),
        ]),
        // A daemon in memory (`FakeHost`) and the chats it serves: the UI-test fixture, which every
        // build carries (the performance tests run against Release), previews' samples, and the
        // tests' fake host.
        .target(name: "SundownFixtures", dependencies: ["SundownKit", "ServerProtocol"]),
        .target(name: "SundownUI", dependencies: [
            "SundownKit", "SundownFixtures", .product(name: "Markdown", package: "swift-markdown"),
        ]),
        // What both test targets share: waiting, observing, building items. Tests only.
        .target(name: "SundownTestSupport", dependencies: ["SundownKit", "SundownFixtures", "ServerProtocol"]),
        .testTarget(name: "SundownKitTests", dependencies: ["SundownKit", "SundownFixtures", "SundownTestSupport"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SundownUITests", dependencies: [
            "SundownUI", "SundownKit", "SundownFixtures", "SundownTestSupport", "ServerProtocol",
        ]),
    ]
)
