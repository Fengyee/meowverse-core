// swift-tools-version: 6.0
import PackageDescription

// Measures the app's on-device furniture recognition on a folder of photos sorted by hand.
// Runs on the Mac only; see README.md.
let package = Package(
    name: "RecognitionEval",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../MeowverseCore")],
    targets: [
        .executableTarget(
            name: "recognition-eval",
            dependencies: [.product(name: "MeowverseCore", package: "MeowverseCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The app's DINOv2 path end to end on the Mac (real model, synthetic pictures): the UI
        // tests mostly run on the colour grid, so this is where the shipped prints are checked.
        .testTarget(
            name: "RecognitionEvalTests",
            dependencies: ["recognition-eval", .product(name: "MeowverseCore", package: "MeowverseCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
