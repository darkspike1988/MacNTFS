// swift-tools-version: 5.10
import Foundation
import PackageDescription

// The FSKit adapter needs the handler based FSKit API of the macOS 27 SDK. It is built only if the SDK has it
// (or NTFS_FSKIT=1 asks for it); NTFS_FSKIT=0 leaves it out. Everything else builds with any Xcode and on Linux.
let fskitAvailable: Bool = {
    if let forced = ProcessInfo.processInfo.environment["NTFS_FSKIT"] { return forced == "1" }
    let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
    let header = developer + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/FSKit.framework/Headers/FSVolumeHandlerResult.h"
    return FileManager.default.fileExists(atPath: header)
}()
let fskitSettings: [SwiftSetting] = fskitAvailable ? [.define("NTFS_FSKIT")] : []

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
            path: "Sources/NTFSFSKit",
            swiftSettings: fskitSettings
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
            path: "Tests/NTFSFSKitTests",
            swiftSettings: fskitSettings
        ),
        .testTarget(
            name: "NTFSCoreTests",
            dependencies: ["NTFSCore"],
            path: "Tests/NTFSCoreTests"
        ),
    ]
)
