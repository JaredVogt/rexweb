// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RexWebChromium",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned to a reviewed revision (v0.2.0 plus the CEF 156.0.30 update).
        // Upstream merges CEF version bumps automatically, so never track a
        // branch; review the diff and move this pin by hand.
        .package(url: "https://github.com/Rajaniraiyn/CefSwift", revision: "880adc05246e94a57a4103a96283d137444f5874"),
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
