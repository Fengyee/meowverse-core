// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeowverseCore",
    // iOS 26.0 like the app (string form: tools 6.0 has no .v26). macOS only runs the tests.
    platforms: [.iOS("26.0"), .macOS(.v15)],
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
                // Written by the b607046 store: see LegacyPickerFixtureTests.
                .copy("Resources/legacy-b607-single-checkpoint"),
                .copy("Resources/legacy-b607-single-checkpoint-furniture"),
                // Written by the schema 11 store (a5ed1ae, before the household categories): see Schema12Tests.
                .copy("Resources/schema11-library"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
