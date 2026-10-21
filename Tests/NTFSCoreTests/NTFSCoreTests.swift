import XCTest
@testable import NTFSCore

final class NTFSCoreTests: XCTestCase {

    // MARK: - BinaryReader Tests

    func testBinaryReaderPrimitives() throws {
        var data = Data()
        // UInt8: 0x42
        data.append(0x42)
        // UInt16 LE: 0x1234
        data.append(contentsOf: [0x34, 0x12])
        // UInt32 LE: 0x11223344
        data.append(contentsOf: [0x44, 0x33, 0x22, 0x11])
        // UInt64 LE: 0x0102030405060708
        data.append(contentsOf: [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])

        var reader = BinaryReader(data: data)
        XCTAssertEqual(try reader.readUInt8(), 0x42)
        XCTAssertEqual(try reader.readUInt16(), 0x1234)
        XCTAssertEqual(try reader.readUInt32(), 0x11223344)
        XCTAssertEqual(try reader.readUInt64(), 0x0102030405060708)
        XCTAssertTrue(reader.isEOF)
    }

    func testBinaryReaderUTF16LE() throws {
        // "Test" in UTF-16LE: 0x0054, 0x0065, 0x0073, 0x0074
        let bytes: [UInt8] = [0x54, 0x00, 0x65, 0x00, 0x73, 0x00, 0x74, 0x00]
        var reader = BinaryReader(data: Data(bytes))
        let str = try reader.readUTF16LEString(characterCount: 4)
        XCTAssertEqual(str, "Test")
    }

    // MARK: - Runlist Decoder Tests

    func testRunlistDecoderSimpleAndFragmented() throws {
        // Run 1: length = 4 clusters, offset delta = +100 (0x64)
        // Header: low nibble = 1 (length size), high nibble = 1 (offset size) -> 0x11
        // Length: 0x04
        // Offset: 0x64
        // Run 2: length = 8 clusters, offset delta = -10 (0xF6 in 1 byte signed)
        // Header: low nibble = 1, high nibble = 1 -> 0x11
        // Length: 0x08
        // Offset: 0xF6 (-10) -> LCN becomes 100 - 10 = 90
        // Run 3: Sparse run (offset size = 0, length size = 2) -> 0x02
        // Length: 0x0020 (32 clusters)
        // Terminator: 0x00
        let runlistData = Data([
            0x11, 0x04, 0x64,
            0x11, 0x08, 0xF6,
            0x02, 0x20, 0x00,
            0x00
        ])

        let runs = try RunlistDecoder.decode(data: runlistData)
        XCTAssertEqual(runs.count, 3)

        XCTAssertEqual(runs[0].clusterCount, 4)
        XCTAssertEqual(runs[0].startingLCN, 100)

        XCTAssertEqual(runs[1].clusterCount, 8)
        XCTAssertEqual(runs[1].startingLCN, 90)

        XCTAssertEqual(runs[2].clusterCount, 32)
        XCTAssertTrue(runs[2].isSparse)
    }

    // MARK: - Fixup Applier Tests

    func testFixupApplicationAndIntegrity() throws {
        // Prepare a 1024-byte record (2 sectors of 512 bytes)
        var recordData = Data(repeating: 0xAA, count: 1024)

        // USA at offset 0x30, update sequence size = 3 (1 USN + 2 sectors)
        let usaOffset = 0x30
        let usn: UInt16 = 0x1234
        let originalSector0Tail: UInt16 = 0xCAFE
        let originalSector1Tail: UInt16 = 0xBEEF

        // Place USN and saved original tails in USA
        recordData[usaOffset] = UInt8(usn & 0xFF)
        recordData[usaOffset + 1] = UInt8((usn >> 8) & 0xFF)
        recordData[usaOffset + 2] = UInt8(originalSector0Tail & 0xFF)
        recordData[usaOffset + 3] = UInt8((originalSector0Tail >> 8) & 0xFF)
        recordData[usaOffset + 4] = UInt8(originalSector1Tail & 0xFF)
        recordData[usaOffset + 5] = UInt8((originalSector1Tail >> 8) & 0xFF)

        // Place USN signature at end of sector 0 (510..511) and sector 1 (1022..1023)
        recordData[510] = UInt8(usn & 0xFF)
        recordData[511] = UInt8((usn >> 8) & 0xFF)
        recordData[1022] = UInt8(usn & 0xFF)
        recordData[1023] = UInt8((usn >> 8) & 0xFF)

        // Apply fixup
        try FixupApplier.applyFixup(
            data: &recordData,
            updateSequenceOffset: usaOffset,
            updateSequenceSize: 3,
            bytesPerSector: 512
        )

        // Verify restored bytes at sector ends
        let sec0Tail = UInt16(recordData[510]) | (UInt16(recordData[511]) << 8)
        let sec1Tail = UInt16(recordData[1022]) | (UInt16(recordData[1023]) << 8)
        XCTAssertEqual(sec0Tail, originalSector0Tail)
        XCTAssertEqual(sec1Tail, originalSector1Tail)
    }

    func testFixupCorruptionDetection() throws {
        var recordData = Data(repeating: 0, count: 1024)
        let usaOffset = 0x30
        let usn: UInt16 = 0x1234
        recordData[usaOffset] = UInt8(usn & 0xFF)
        recordData[usaOffset + 1] = UInt8((usn >> 8) & 0xFF)

        // Put WRONG signature at end of sector 0
        recordData[510] = 0x99
        recordData[511] = 0x99

        XCTAssertThrowsError(
            try FixupApplier.applyFixup(
                data: &recordData,
                updateSequenceOffset: usaOffset,
                updateSequenceSize: 2,
                bytesPerSector: 512
            )
        ) { error in
            guard case NTFSError.fixupVerificationFailed = error else {
                XCTFail("Expected fixupVerificationFailed error, got \(error)")
                return
            }
        }
    }

    // MARK: - Boot Sector Parsing Tests

    func testBootSectorParsing() throws {
        var bootData = Data(repeating: 0, count: 512)
        // Jump instruction
        bootData[0] = 0xEB
        bootData[1] = 0x52
        bootData[2] = 0x90

        // OEM ID "NTFS    "
        let oemBytes: [UInt8] = Array("NTFS    ".utf8)
        bootData.replaceSubrange(3..<11, with: oemBytes)

        // Bytes per sector = 512 (0x0200)
        bootData[0x0B] = 0x00
        bootData[0x0C] = 0x02

        // Sectors per cluster = 8 (4096 bytes)
        bootData[0x0D] = 0x08

        // Total sectors = 204800 (100 MB)
        var totalSec: UInt64 = 204800
        withUnsafeBytes(of: &totalSec) { buf in
            bootData.replaceSubrange(0x28..<0x30, with: buf)
        }

        // MFT LCN = 4 (cluster 4)
        var mftLCN: UInt64 = 4
        withUnsafeBytes(of: &mftLCN) { buf in
            bootData.replaceSubrange(0x30..<0x38, with: buf)
        }

        // Clusters per MFT record = 0xF6 (-10 -> 1024 bytes)
        bootData[0x40] = 0xF6

        // Clusters per Index record = 0xF6 (1024 bytes)
        bootData[0x44] = 0xF6

        // Boot signature 0x55 0xAA at 510..511
        bootData[510] = 0x55
        bootData[511] = 0xAA

        let boot = try BootSector(data: bootData)
        XCTAssertEqual(boot.oemID, "NTFS    ")
        XCTAssertEqual(boot.bytesPerSector, 512)
        XCTAssertEqual(boot.sectorsPerCluster, 8)
        XCTAssertEqual(boot.clusterSizeBytes, 4096)
        XCTAssertEqual(boot.totalSectors, 204800)
        XCTAssertEqual(boot.mftClusterNumber, 4)
        XCTAssertEqual(boot.mftRecordSizeBytes, 1024)
        XCTAssertEqual(boot.indexRecordSizeBytes, 1024)
        XCTAssertEqual(boot.mftByteOffset, 4 * 4096)
    }

    // MARK: - FILETIME Date Conversion

    func testFileTimeConversion() {
        let now = Date()
        let fileTime = FileTimeConverter.toFileTime(date: now)
        let roundtripDate = FileTimeConverter.toDate(fileTime: fileTime)

        // Precision within 1 millisecond
        XCTAssertEqual(now.timeIntervalSince1970, roundtripDate.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Phase 3 Write Engine Tests

    func testBitmapManagerAllocationAndFree() throws {
        // 8 bytes = 64 bits, all initially free (0x00)
        var bitmap = BitmapManager(data: Data(repeating: 0x00, count: 8))
        XCTAssertEqual(bitmap.totalBits, 64)
        XCTAssertFalse(bitmap.isAllocated(at: 10))

        // Allocate 4 contiguous bits starting at 10
        let allocatedStart = try bitmap.allocateContiguous(count: 4, startIndex: 10)
        XCTAssertEqual(allocatedStart, 10)

        // Verify bits 10, 11, 12, 13 are allocated
        XCTAssertTrue(bitmap.isAllocated(at: 10))
        XCTAssertTrue(bitmap.isAllocated(at: 11))
        XCTAssertTrue(bitmap.isAllocated(at: 12))
        XCTAssertTrue(bitmap.isAllocated(at: 13))
        XCTAssertFalse(bitmap.isAllocated(at: 9))
        XCTAssertFalse(bitmap.isAllocated(at: 14))

        // Free bits 11 and 12
        try bitmap.freeContiguous(startIndex: 11, count: 2)
        XCTAssertTrue(bitmap.isAllocated(at: 10))
        XCTAssertFalse(bitmap.isAllocated(at: 11))
        XCTAssertFalse(bitmap.isAllocated(at: 12))
        XCTAssertTrue(bitmap.isAllocated(at: 13))
    }

    func testDataRunEncoderAndDecoderRoundtrip() throws {
        let originalRuns = [
            DataRun(clusterCount: 16, startingLCN: 1024),
            DataRun(clusterCount: 32, startingLCN: 2048),
            DataRun(clusterCount: 8, startingLCN: 1500), // Jump backwards (negative delta)
            DataRun(clusterCount: 4, startingLCN: nil)   // Sparse run
        ]

        let encodedBytes = DataRunEncoder.encode(runs: originalRuns)
        let decodedRuns = try RunlistDecoder.decode(data: encodedBytes)

        XCTAssertEqual(decodedRuns.count, originalRuns.count)
        for i in 0..<originalRuns.count {
            XCTAssertEqual(decodedRuns[i].clusterCount, originalRuns[i].clusterCount)
            XCTAssertEqual(decodedRuns[i].startingLCN, originalRuns[i].startingLCN)
            XCTAssertEqual(decodedRuns[i].isSparse, originalRuns[i].isSparse)
        }
    }

    func testMFTRecordBuilderGeneratesValidRecord() throws {
        let expectedPayload = "SwiftNTFS Write Engine Resident Payload Verification".data(using: .utf8)!
        let fileName = "Document.txt"

        let recordData = try MFTRecordBuilder.buildFileRecord(
            recordNumber: 42,
            sequenceNumber: 3,
            parentDirectoryRecordNumber: 5,
            fileName: fileName,
            fileContent: expectedPayload
        )

        XCTAssertEqual(recordData.count, 1024)

        // Parse generated record back with MFTRecord parser to verify integrity & fixups
        let parsed = try MFTRecord(recordNumber: 42, rawData: recordData, bytesPerSector: 512)
        XCTAssertEqual(parsed.header.magic, "FILE")
        XCTAssertTrue(parsed.isInUse)
        XCTAssertFalse(parsed.isDirectory)
        XCTAssertEqual(parsed.header.sequenceNumber, 3)

        // Check file name attribute
        guard let fn = parsed.primaryFileName else {
            XCTFail("Missing primary file name attribute")
            return
        }
        XCTAssertEqual(fn.name, fileName)
        XCTAssertEqual(fn.realSize, UInt64(expectedPayload.count))
        XCTAssertEqual(fn.parentDirectoryRecordNumber, 5)

        // Check resident data attribute
        guard let dataAttr = parsed.defaultDataAttribute,
              let resData = dataAttr.residentData else {
            XCTFail("Missing or non-resident data attribute")
            return
        }
        XCTAssertEqual(resData, expectedPayload)
    }
}
