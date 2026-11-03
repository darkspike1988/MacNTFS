// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacNTFS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NTFSCore", targets: ["NTFSCore"]),
        .executable(name: "macntfs", targets: ["MacNTFSCli"])
    ],
    targets: [
        .target(
            name: "NTFSCore",
            dependencies: [],
            path: "Sources/NTFSCore"
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
            name: "NTFSCoreTests",
            dependencies: ["NTFSCore"],
            path: "Tests/NTFSCoreTests"
        ),
    ]
)
