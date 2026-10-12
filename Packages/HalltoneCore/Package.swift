// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HalltoneCore",
    platforms: [.macOS("14.2"), .iOS(.v17)],
    products: [
        .library(name: "HalltoneCore", targets: ["HalltoneCore"]),
        .library(name: "HalltoneSender", targets: ["HalltoneSender"]),
        .library(name: "HalltoneReceiver", targets: ["HalltoneReceiver"]),
    ],
    targets: [
        // Tiny C target: lock-free SPSC ring buffer (stdatomic), usable from both audio callbacks.
        .target(name: "CHalltone", path: "Sources/CHalltone"),
        // Vendored libopus 1.5.2 (float build, no platform intrinsics), compiled for macOS and iOS.
        .target(
            name: "COpus",
            path: "Sources/COpus",
            exclude: ["opus/AUTHORS", "opus/COPYING", "opus/LICENSE_PLEASE_READ.txt", "opus/README"],
            sources: ["opus/src", "opus/celt", "opus/silk"],
            publicHeadersPath: "opus/include",
            cSettings: [
                .headerSearchPath("opus/include"),
                .headerSearchPath("opus/celt"),
                .headerSearchPath("opus/silk"),
                .headerSearchPath("opus/silk/float"),
                .headerSearchPath("opus/src"),
                .define("OPUS_BUILD"),
                .define("VAR_ARRAYS", to: "1"),
                .define("HAVE_LRINT", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
                .define("FLOAT_APPROX"),
            ]
        ),
        // Non-variadic wrappers around opus_*_ctl for Swift.
        .target(name: "COpusShim", dependencies: ["COpus"], path: "Sources/COpusShim"),
        // Shared protocol + buffering logic (no audio hardware).
        .target(name: "HalltoneCore", dependencies: ["CHalltone", "COpus", "COpusShim"]),
        // macOS-only: process-tap capture, UDP listener, subscriber tracking.
        .target(name: "HalltoneSender", dependencies: ["HalltoneCore"]),
        // macOS + iOS: UDP subscriber, jitter-buffer feed, AVAudioEngine playback.
        .target(name: "HalltoneReceiver", dependencies: ["HalltoneCore"]),
        .testTarget(name: "HalltoneCoreTests", dependencies: ["HalltoneCore", "HalltoneReceiver"]),
    ],
    swiftLanguageVersions: [.v5]
)
