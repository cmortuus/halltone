// swift-tools-version: 5.10
import PackageDescription

// halltone-linux: the Ubuntu sender. The streaming logic is `HalltoneSenderCore` (shared with the
// Mac app); this package adds PulseAudio capture (works on PipeWire through pipewire-pulse), the
// Avahi advertiser, config and the executable.
//
// The PulseAudio target exists only on Linux, so the rest (config, address picking, tone source,
// the integration test) also builds and runs on a Mac for development.
#if os(Linux)
let pulseTargets: [Target] = [
    .systemLibrary(name: "CPulseSimple", pkgConfig: "libpulse-simple",
                   providers: [.apt(["libpulse-dev"])]),
]
let pulseDependencies: [Target.Dependency] = ["CPulseSimple"]
#else
let pulseTargets: [Target] = []
let pulseDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "halltone-linux",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "halltone-linux", targets: ["halltone-linux"]),
    ],
    dependencies: [
        .package(path: "../../Packages/HalltoneCore"),
        .package(path: "../../Packages/HalltoneDialog"),
    ],
    targets: pulseTargets + [
        .target(
            name: "HalltoneLinuxKit",
            dependencies: [
                .product(name: "HalltoneCore", package: "HalltoneCore"),
                .product(name: "HalltoneSenderCore", package: "HalltoneCore"),
                .product(name: "HalltoneDialog", package: "HalltoneDialog"),
                .product(name: "HalltoneDialogEval", package: "HalltoneDialog"),
            ] + pulseDependencies
        ),
        .executableTarget(name: "halltone-linux", dependencies: ["HalltoneLinuxKit"]),
        .testTarget(
            name: "HalltoneLinuxTests",
            dependencies: [
                "HalltoneLinuxKit",
                .product(name: "HalltoneCore", package: "HalltoneCore"),
                .product(name: "HalltoneDialog", package: "HalltoneDialog"),
                .product(name: "HalltoneDialogEval", package: "HalltoneDialog"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
