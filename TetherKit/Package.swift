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
        // Generated protocol types live with the server; local path during development.
        .package(name: "TetherProtocol", path: "../../tether-server"),
    ],
    targets: [
        .target(name: "TetherKit", dependencies: [.product(name: "TetherProtocol", package: "TetherProtocol")]),
        .target(name: "TetherUI", dependencies: ["TetherKit"]),
        .testTarget(name: "TetherKitTests", dependencies: ["TetherKit"]),
    ]
)
