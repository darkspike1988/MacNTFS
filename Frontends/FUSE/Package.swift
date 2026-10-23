// swift-tools-version: 5.10
import PackageDescription

// Separate package: building it requires macFUSE (libfuse3), the main package does not.
let package = Package(
    name: "MacNTFSFUSE",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "MacNTFS", path: "../..")],
    targets: [
        .systemLibrary(name: "CFuse3", path: "Sources/CFuse3", pkgConfig: "fuse3"),
        .executableTarget(
            name: "macntfs-fuse",
            dependencies: ["CFuse3", .product(name: "NTFSCore", package: "MacNTFS")],
            path: "Sources/macntfs-fuse",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I/usr/local/include/fuse3"])],
            linkerSettings: [.unsafeFlags(["-L/usr/local/lib", "-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])]
        ),
    ]
)
