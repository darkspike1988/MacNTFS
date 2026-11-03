import XCTest
@testable import NTFSCore

final class VolumeStateTests: XCTestCase {

    private let mounts = [
        MountInfo(device: "/dev/disk3s1s1", mountPoint: "/", fileSystemType: "apfs", isReadOnly: true),
        MountInfo(device: "/dev/disk4s1", mountPoint: "/Volumes/USB", fileSystemType: "ntfs", isReadOnly: false)
    ]

    func testRawAndBlockDeviceNodesAreTheSameDevice() {
        XCTAssertEqual(MountCheck.mount(forDevice: "/dev/rdisk4s1", in: mounts)?.mountPoint, "/Volumes/USB")
        XCTAssertEqual(MountCheck.mount(forDevice: "/dev/disk4s1", in: mounts)?.mountPoint, "/Volumes/USB")
        XCTAssertNil(MountCheck.mount(forDevice: "/dev/rdisk5s1", in: mounts))
        XCTAssertNil(MountCheck.mount(forDevice: "disk.img", in: mounts), "an image file is never a mounted device")
    }

    func testCurrentMountsIncludeTheRootFileSystem() {
        #if canImport(Darwin)
        let current = MountCheck.currentMounts()
        XCTAssertTrue(current.contains { $0.mountPoint == "/" }, "getmntinfo must list the root volume")
        #endif
    }

    func testMiniImageIsNotHibernatedAndNotDirty() throws {
        let volume = try NTFSVolume(blockDevice: MemoryBlockDevice(data: try Fixtures.miniImage()))
        XCTAssertFalse(volume.isDirty)
        XCTAssertEqual(try volume.hibernationState(), .absent)
    }
}
