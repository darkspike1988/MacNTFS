// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacNTFS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "NTFSCore", targets: ["NTFSCore"]),
        .executable(name: "macntfs", targets: ["MacNTFSCli"]),
        .executable(name: "MacNTFSApp", targets: ["MacNTFSApp"]),
        .executable(name: "MacNTFSFileSystemExtension", targets: ["MacNTFSFileSystemExtension"])
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
            name: "MacNTFSApp",
            dependencies: ["NTFSCore"],
            path: "Sources/MacNTFSApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "NTFSCoreTests",
            dependencies: ["NTFSCore"],
            path: "Tests/NTFSCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "MacNTFSFileSystemExtension",
            dependencies: ["NTFSCore"],
            path: "Sources/MacNTFSFileSystemExtension"
        ),
    ]
)
