#if canImport(FSKit)
import Foundation
import FSKit
import XCTest
@testable import NTFSCore

@available(macOS 15.4, *)
final class FSKitAdapterTests: XCTestCase {
    private func volume() throws -> MacNTFSFSVolume {
        let device = MemoryBlockDevice(data: Data(count: 32 * 1024 * 1024))
        try NTFSFormatter.format(device: device, options: .init(volumeName: "FSKIT"))
        return MacNTFSFSVolume(coreVolume: try NTFSVolume(blockDevice: device))
    }
    private func create(_ volume: MacNTFSFSVolume, _ name: String, _ type: FSItem.ItemType = .file, parent: FSItem? = nil) throws -> FSItem {
        var result: FSItem?, failure: Error?
        volume.createItem(named: FSFileName(string: name), type: type, inDirectory: parent ?? volume.rootItem, attributes: FSItem.SetAttributesRequest()) { item, _, error in result = item; failure = error }
        if let failure { throw failure }; return try XCTUnwrap(result)
    }
    func testFinderStyleCreateWriteTruncateRenameRemovePersists() throws {
        let volume = try volume()
        let directory = try create(volume, "Documents", .directory)
        let file = try create(volume, "report.txt", parent: directory)
        let payload = Data(repeating: 0x61, count: 20000)
        var failure: Error?, written = 0
        volume.write(contents: payload, to: file, at: 0) { count, error in written = count; failure = error }
        XCTAssertNil(failure); XCTAssertEqual(written, payload.count)
        let resize = FSItem.SetAttributesRequest(); resize.size = 12345
        volume.setAttributes(resize, on: file) { _, error in failure = error }
        XCTAssertNil(failure)
        volume.renameItem(directory, inDirectory: volume.rootItem, named: FSFileName(string: "Documents"), to: FSFileName(string: "Renamed"), inDirectory: volume.rootItem, overItem: nil) { _, error in failure = error }
        XCTAssertNil(failure)
        // Existing child handles must continue to work after their parent moves.
        let child = try create(volume, "another.bin", parent: directory)
        volume.write(contents: Data([1, 2, 3]), to: child, at: 0) { _, error in failure = error }
        XCTAssertNil(failure)
        let reopened = try NTFSVolume(blockDevice: volume.coreVolume.blockDevice)
        XCTAssertEqual(try reopened.readFile(at: "/Renamed/report.txt"), Data(payload.prefix(12345)))
        XCTAssertEqual(try reopened.readFile(at: "/Renamed/another.bin"), Data([1, 2, 3]))
        volume.removeItem(file, named: FSFileName(string: "report.txt"), fromDirectory: directory) { failure = $0 }
        XCTAssertNil(failure)
        XCTAssertThrowsError(try reopened.readFile(at: "/Renamed/report.txt"))
    }
    func testReadOnlyResourceRejectsWritesAndNegativeOffsets() throws {
        let volume = try volume()
        let file = try create(volume, "data.bin")
        guard let device = volume.coreVolume.blockDevice as? MemoryBlockDevice else { return XCTFail("Expected memory device") }
        device.isWritable = false
        let before = try device.read(offset: 0, count: Int(device.size))
        var failure: Error?, count = -1
        volume.write(contents: Data([1]), to: file, at: 0) { count = $0; failure = $1 }
        XCTAssertNotNil(failure); XCTAssertEqual(count, 0)
        XCTAssertEqual(try device.read(offset: 0, count: Int(device.size)), before)
        volume.write(contents: Data([1]), to: file, at: -1) { count = $0; failure = $1 }
        XCTAssertEqual((failure as NSError?)?.code, Int(EINVAL)); XCTAssertEqual(count, 0)
    }
    func testCaseInsensitiveLookupAndPersistentIDs() throws {
        let volume = try volume()
        let created = try create(volume, "Report.txt")
        var found: FSItem?, failure: Error?, storedName: String?
        volume.lookupItem(named: FSFileName(string: "REPORT.TXT"), inDirectory: volume.rootItem) { item, name, error in found = item; storedName = name?.string; failure = error }
        XCTAssertNil(failure); XCTAssertTrue(created === found); XCTAssertEqual(storedName, "Report.txt")
        var attrs: FSItem.Attributes?
        volume.getAttributes(FSItem.GetAttributesRequest(), of: volume.rootItem) { result, error in attrs = result; failure = error }
        XCTAssertNil(failure); XCTAssertEqual(attrs?.fileID.rawValue, 2)
        XCTAssertThrowsError(try create(volume, "REPORT.TXT"))
    }
}
#endif
