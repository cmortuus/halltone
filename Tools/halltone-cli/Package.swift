// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "halltone-cli",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(path: "../../Packages/HalltoneCore"),
    ],
    targets: [
        .executableTarget(
            name: "halltone-cli",
            dependencies: [
                .product(name: "HalltoneCore", package: "HalltoneCore"),
                .product(name: "HalltoneSender", package: "HalltoneCore"),
                .product(name: "HalltoneReceiver", package: "HalltoneCore"),
            ],
            linkerSettings: [
                // Embed an Info.plist so TCC has a usage description + bundle id for the tap prompt.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/halltone-cli/Info.plist"]),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
