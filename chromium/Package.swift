// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RexWebChromium",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Local checkout while the engine is being built; pinned to a
        // revision of the upstream repository before this ships.
        .package(name: "CefSwift", path: "../../CefSwift"),
    ],
    targets: [
        .executableTarget(
            name: "RexWebChromium",
            dependencies: [.product(name: "CefKit", package: "CefSwift")],
            exclude: ["cefapp.json"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
