// The FSKit adapter can only be tested where FSKit exists, and without the FSKit daemon: the calls that take an
// FSContext, a packer or a data buffer cannot be made here, because FSKit does not let a client create those.
// What is tested: the mapping of attributes and identifiers, the capabilities, and that writes are refused.
#if canImport(FSKit) && NTFS_FSKIT
import XCTest
import FSKit
import NTFSCore
@testable import NTFSFSKit

@available(macOS 27.0, *)
final class AdapterTests: XCTestCase {
    private func makeVolume() throws -> (volume: NTFSFSVolume, fileSystem: ReadOnlyFileSystem) {
        let image = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mini.img")
        let ntfs = try NTFSVolume(blockDevice: MemoryBlockDevice(data: Data(contentsOf: image)))
        let fileSystem = ReadOnlyFileSystem(volume: ntfs)
        let volume = NTFSFSVolume(fileSystem: fileSystem, volumeID: FSVolume.Identifier(uuid: UUID()), name: FSFileName(string: "MINI"))
        return (volume, fileSystem)
    }

    func testAttributesOfAFile() throws {
        let (volume, fileSystem) = try makeVolume()
        let big = try fileSystem.lookup(name: "big.bin", inDirectory: ReadOnlyFileSystem.rootID)
        let attributes = volume.attributes(of: big, uid: 501, gid: 20)
        XCTAssertEqual(attributes.type, .file)
        XCTAssertEqual(attributes.mode, 0o444, "read-only, no execute")
        XCTAssertEqual(attributes.size, 20000)
        XCTAssertGreaterThanOrEqual(attributes.allocSize, 20000)
        XCTAssertEqual(attributes.uid, 501)
        XCTAssertEqual(attributes.gid, 20)
        XCTAssertEqual(attributes.linkCount, 1)
        XCTAssertEqual(attributes.fileID, FSItem.Identifier(big.id))
        XCTAssertEqual(attributes.parentID, .rootDirectory)
        XCTAssertGreaterThan(attributes.modifyTime.tv_sec, 1_500_000_000)
    }

    func testRootAndDirectoryIdentifiers() throws {
        let (volume, fileSystem) = try makeVolume()
        let root = try fileSystem.item(id: ReadOnlyFileSystem.rootID)
        let rootAttributes = volume.attributes(of: root, uid: 0, gid: 0)
        XCTAssertEqual(rootAttributes.type, .directory)
        XCTAssertEqual(rootAttributes.mode, 0o555)
        XCTAssertEqual(rootAttributes.fileID, .rootDirectory)
        XCTAssertEqual(rootAttributes.parentID, .parentOfRoot)
        // NTFS keeps its own records below 24, so user items never collide with FSKit's reserved 0 to 2.
        let dir = try fileSystem.lookup(name: "dir", inDirectory: ReadOnlyFileSystem.rootID)
        XCTAssertGreaterThanOrEqual(dir.id, 24)
        XCTAssertEqual(NTFSFSVolume.itemID(dir.id), FSItem.Identifier(dir.id))
        XCTAssertEqual(NTFSFSVolume.itemID(ReadOnlyFileSystem.rootID), .rootDirectory)
    }

    func testCapabilitiesDescribeAReadOnlyCaseInsensitiveVolume() throws {
        let (volume, _) = try makeVolume()
        let capabilities = volume.supportedVolumeCapabilities
        XCTAssertEqual(capabilities.caseFormat, .insensitiveCasePreserving)
        XCTAssertTrue(capabilities.supportsSymbolicLinks)
        XCTAssertTrue(capabilities.supportsHardLinks)
        XCTAssertTrue(capabilities.supports64BitObjectIDs)
        XCTAssertTrue(capabilities.doesNotSupportSettingFilePermissions)
        XCTAssertEqual(volume.maximumNameLength, 255)
        let statistics = volume.volumeStatistics
        XCTAssertEqual(statistics.blockSize, 4096)
        XCTAssertEqual(statistics.freeBlocks, 0)
        XCTAssertEqual(statistics.availableBytes, 0)
    }

    func testWriteIsRefusedWithEROFS() throws {
        let (volume, _) = try makeVolume()
        let item = NTFSItem(id: 30)
        let answered = expectation(description: "reply")
        volume.write(contents: Data([1, 2, 3]), to: item, at: 0) { result, error in
            XCTAssertNil(result)
            XCTAssertEqual((error as NSError?)?.domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError?)?.code, Int(EROFS))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }

    func testVolumeUUIDIsStableAndDependsOnTheSerialNumber() {
        let a = NTFSFileSystem.uuid(serial: 0x1122_3344_5566_7788)
        XCTAssertEqual(a, NTFSFileSystem.uuid(serial: 0x1122_3344_5566_7788))
        XCTAssertNotEqual(a, NTFSFileSystem.uuid(serial: 0x1122_3344_5566_7789))
        XCTAssertTrue(a.uuidString.replacingOccurrences(of: "-", with: "").hasSuffix("1122334455667788"), a.uuidString)
    }
}
#endif
