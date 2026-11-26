// swift-tools-version: 5.10
import PackageDescription

// Standalone real-time dialog detector. No Apple frameworks: builds on macOS and Linux.
let package = Package(
    name: "HalltoneDialog",
    products: [
        .library(name: "HalltoneDialog", targets: ["HalltoneDialog"]),
        .executable(name: "halltone-dialog-eval", targets: ["halltone-dialog-eval"]),
    ],
    targets: [
        // Vendored libfvad (WebRTC VAD, BSD-3-Clause). See Sources/CFVAD/VENDORED.md.
        .target(
            name: "CFVAD",
            path: "Sources/CFVAD",
            exclude: ["LICENSE", "VENDORED.md"],
            sources: ["src"],
            publicHeadersPath: "include"
        ),
        // The detector itself: center extraction, VAD, gates, hysteresis.
        .target(name: "HalltoneDialog", dependencies: ["CFVAD"]),
        // WAV reading, resampling, label parsing and scoring, shared by the CLI and the tests.
        .target(name: "HalltoneDialogEval", dependencies: ["HalltoneDialog"]),
        .executableTarget(name: "halltone-dialog-eval", dependencies: ["HalltoneDialog", "HalltoneDialogEval"]),
        .testTarget(name: "HalltoneDialogTests", dependencies: ["HalltoneDialog", "HalltoneDialogEval"]),
    ],
    swiftLanguageVersions: [.v5]
)
