// swift-tools-version: 5.10
// SwiftPM build of the menu bar app (used by make-bundle.sh for Xcode-free local builds).
// The Xcode project generated from project.yml builds the same sources.
import PackageDescription

let package = Package(
    name: "HalltoneMac",
    platforms: [.macOS("14.2")],
    dependencies: [.package(path: "../Packages/HalltoneCore")],
    targets: [
        .executableTarget(
            name: "HalltoneMac",
            dependencies: [
                .product(name: "HalltoneCore", package: "HalltoneCore"),
                .product(name: "HalltoneSender", package: "HalltoneCore"),
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Info.plist"]),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
