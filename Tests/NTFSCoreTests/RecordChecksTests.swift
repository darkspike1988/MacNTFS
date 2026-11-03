import XCTest
@testable import NTFSCore

/// Checks that damaged or stale records are rejected and never read as data. Each test changes bytes of
/// the committed ntfs-3g image and names the field it changes.
final class RecordChecksTests: XCTestCase {

    func testRecordMarkedBadByChkdskIsRejected() throws {
        let volume = try Fixtures.patchedVolume(path: "/small.txt") { image, record, _, _ in
            image.replaceSubrange(record..<(record + 4), with: Data("BAAD".utf8))
        }
        XCTAssertThrowsError(try volume.readFile(at: "/small.txt")) { error in
            guard case NTFSError.invalidSignature = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testRecordWithTheWrongNumberOfUpdateSequenceEntriesIsRejected() throws {
        // The update sequence size sits at offset 6. A 1024-byte record needs 3 entries.
        let volume = try Fixtures.patchedVolume(path: "/small.txt") { image, record, _, _ in
            image[record + 6] = 1
        }
        XCTAssertThrowsError(try volume.readFile(at: "/small.txt")) { error in
            guard case NTFSError.corruptRecord = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testRecordThatNamesAnotherRecordNumberIsRejected() throws {
        // NTFS 3.1 records store their own number at offset 0x2C.
        let volume = try Fixtures.patchedVolume(path: "/small.txt") { image, record, _, _ in
            image[record + 0x2C] = 0x39
            image[record + 0x2D] = 0x30  // 12345
        }
        XCTAssertThrowsError(try volume.readFile(at: "/small.txt")) { error in
            guard case NTFSError.corruptRecord = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testIndexEntryWithAnOldSequenceNumberIsNotFollowed() throws {
        // The record's sequence number (offset 0x10) changed after the directory entry was made.
        let volume = try Fixtures.patchedVolume(path: "/small.txt") { image, record, _, _ in
            image[record + 0x10] = image[record + 0x10] &+ 1
        }
        XCTAssertThrowsError(try volume.readFile(at: "/small.txt")) { error in
            guard case NTFSError.corruptDirectoryIndex = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testIndexEntryThatPointsToAFreeRecordIsNotFollowed() throws {
        // Flag bit 0 at offset 0x16 is "in use".
        let volume = try Fixtures.patchedVolume(path: "/small.txt") { image, record, _, _ in
            image[record + 0x16] &= ~0x01
        }
        XCTAssertThrowsError(try volume.readFile(at: "/small.txt")) { error in
            guard case NTFSError.corruptDirectoryIndex = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testIndexEntryThatPointsToAnExtensionRecordIsNotFollowed() throws {
        // The base record reference (offset 0x20) of a file record is zero. A non-zero value makes it an extension record.
        let volume = try Fixtures.patchedVolume(path: "/small.txt") { image, record, _, _ in
            image[record + 0x20] = 7
        }
        XCTAssertThrowsError(try volume.readFile(at: "/small.txt")) { error in
            guard case NTFSError.corruptDirectoryIndex = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testUnknownCompressionFormatIsRefused() throws {
        // Bit 0 of the attribute flags is LZNT1. Another bit of the compression mask is a format we do not know.
        let volume = try Fixtures.patchedVolume(path: "/big.bin") { image, record, _, data in
            image[record + data + 12] |= 0x02
        }
        XCTAssertThrowsError(try volume.readFile(at: "/big.bin")) { error in
            guard case NTFSError.unsupported(.compressionFormat) = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testMissingStreamIsAnError() throws {
        let volume = try NTFSVolume(blockDevice: MemoryBlockDevice(data: try Fixtures.miniImage()))
        XCTAssertThrowsError(try volume.readFile(at: "/small.txt", stream: "nope")) { error in
            guard case NTFSError.attributeNotFound = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testUnreadableVolumeRecordMakesTheFlagsUnknown() throws {
        let intact = try NTFSVolume(blockDevice: MemoryBlockDevice(data: try Fixtures.miniImage()))
        XCTAssertTrue(intact.volumeFlagsKnown)

        // Break $Volume (record 3). The volume still opens, but the dirty flag cannot be read.
        let image = try Fixtures.patchedImage(try Fixtures.miniImage(), path: "/$Volume") { image, record, _, _ in
            image.replaceSubrange(record..<(record + 4), with: Data("XXXX".utf8))
        }
        let broken = try NTFSVolume(blockDevice: MemoryBlockDevice(data: image))
        XCTAssertFalse(broken.volumeFlagsKnown, "an unreadable $Volume must not look like a clean volume")
    }
}
