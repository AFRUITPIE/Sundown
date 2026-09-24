// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TetherKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TetherKit", targets: ["TetherKit"]),
        .library(name: "TetherUI", targets: ["TetherUI"]),
    ],
    dependencies: [
        // Generated protocol types are published by the server repository as a Swift package.
        // Versioned rather than a sibling path, so this repo can be cloned and built on its own.
        // To work on the protocol, override it with the local checkout instead of editing this:
        //   swift package edit TetherProtocol --path ../../tether-server
        // or add that folder to the Xcode workspace, which takes precedence over the remote.
        .package(url: "https://github.com/AFRUITPIE/tether-server.git", from: "0.1.0"),
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
