// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacNTFS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NTFSCore", targets: ["NTFSCore"]),
        .library(name: "NTFSFSKit", targets: ["NTFSFSKit"]),
        .executable(name: "macntfs", targets: ["MacNTFSCli"])
    ],
    targets: [
        .target(
            name: "NTFSCore",
            dependencies: [],
            path: "Sources/NTFSCore"
        ),
        // The FSKit adapter. It has code on macOS only; the app extension that loads it is an Xcode target.
        .target(
            name: "NTFSFSKit",
            dependencies: ["NTFSCore"],
            path: "Sources/NTFSFSKit"
        ),
        .executableTarget(
            name: "MacNTFSCli",
            dependencies: ["NTFSCore"],
            path: "Sources/MacNTFSCli"
        ),
        .executableTarget(
            name: "NTFSFuzz",
            dependencies: ["NTFSCore"],
            path: "Sources/NTFSFuzz"
        ),
        .testTarget(
            name: "NTFSFSKitTests",
            dependencies: ["NTFSFSKit", "NTFSCore"],
            path: "Tests/NTFSFSKitTests"
        ),
        .testTarget(
            name: "NTFSCoreTests",
            dependencies: ["NTFSCore"],
            path: "Tests/NTFSCoreTests"
        ),
    ]
)
