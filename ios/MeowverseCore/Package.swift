// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeowverseCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MeowverseCore", targets: ["MeowverseCore"]),
    ],
    targets: [
        .target(
            name: "MeowverseCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeowverseCoreTests",
            dependencies: ["MeowverseCore"],
            resources: [
                .copy("Resources/semantic-furniture.catalog.json"),
                // Written by the real web backup writer: scripts/ios/make-web-backup-fixture.test.ts
                .copy("Resources/web-v6-synthetic.zip"),
                .copy("Resources/web-v6-synthetic.sha256.json"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
