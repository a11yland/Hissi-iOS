// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HissiCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HissiCore", exclude: ["Colors.xcassets"]),
        .testTarget(
            name: "HissiCoreTests",
            dependencies: ["HissiCore"],
            path: "Tests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
