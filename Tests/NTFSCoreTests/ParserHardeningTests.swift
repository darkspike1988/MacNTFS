import XCTest
@testable import NTFSCore

/// Checks that hostile or damaged input produces an error or correct data, never a crash or wrong bytes.
/// Fixtures come from the committed ntfs-3g image Tests/Fixtures/mini.img.
final class ParserHardeningTests: XCTestCase {

    // MARK: - Boot sector

    func testBootSectorRejectsHostileValues() throws {
        let valid = Data(try Fixtures.miniImage().prefix(512))
        XCTAssertNoThrow(try BootSector(data: valid))

        func mutated(_ patch: (inout Data) -> Void) -> Data {
            var copy = valid
            patch(&copy)
            return copy
        }

        let cases: [(String, Data)] = [
            ("MFT record exponent -128 (Int8.min)", mutated { $0[0x40] = 0x80 }),
            ("MFT record exponent -64", mutated { $0[0x40] = 0xC0 }),
            ("MFT record of 127 clusters", mutated { $0[0x40] = 0x7F }),
            ("MFT record of 0 clusters", mutated { $0[0x40] = 0x00 }),
            ("index record exponent -128", mutated { $0[0x44] = 0x80 }),
            ("sector size 8192", mutated { $0[0x0B] = 0x00; $0[0x0C] = 0x20 }),
            ("sector size 0", mutated { $0[0x0B] = 0x00; $0[0x0C] = 0x00 }),
            ("sectors per cluster 0", mutated { $0[0x0D] = 0x00 }),
            ("total sectors UInt64.max", mutated { Fixtures.put64(&$0, 0x28, UInt64.max) }),
            ("total sectors 0", mutated { Fixtures.put64(&$0, 0x28, 0) }),
            ("MFT cluster UInt64.max", mutated { Fixtures.put64(&$0, 0x30, UInt64.max) })
        ]
        for (name, data) in cases {
            XCTAssertThrowsError(try BootSector(data: data), name) { error in
                guard case NTFSError.invalidBootSector = error else {
                    return XCTFail("\(name): unexpected error \(error)")
                }
            }
        }
    }

    // MARK: - Fixups

    func testFixupUses512ByteBlocksOnLargeRecords() throws {
        // A 4096-byte record is protected in eight 512-byte blocks, whatever the sector size is.
        var record = Data(repeating: 0xAA, count: 4096)
        let usaOffset = 0x30
        let blocks = 8
        record[usaOffset] = 0x34
        record[usaOffset + 1] = 0x12
        for i in 0..<blocks {
            let saved = UInt16(0xBEE0 + i)
            record[usaOffset + 2 + 2 * i] = UInt8(saved & 0xFF)
            record[usaOffset + 3 + 2 * i] = UInt8(saved >> 8)
            let end = (i + 1) * 512 - 2
            record[end] = 0x34
            record[end + 1] = 0x12
        }

        try FixupApplier.applyFixup(data: &record, updateSequenceOffset: usaOffset, updateSequenceSize: blocks + 1)

        for i in 0..<blocks {
            let end = (i + 1) * 512 - 2
            XCTAssertEqual(UInt16(record[end]) | (UInt16(record[end + 1]) << 8), UInt16(0xBEE0 + i), "block \(i)")
        }
    }

    func testFixupRejectsArrayLargerThanRecord() {
        var record = Data(repeating: 0, count: 1024)
        XCTAssertThrowsError(try FixupApplier.applyFixup(data: &record, updateSequenceOffset: 0x30, updateSequenceSize: 10)) { error in
            guard case NTFSError.outOfBounds = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    // MARK: - Run lists

    func testRunlistDecoderRejectsLCNOverflow() {
        var bytes = Data()
        for _ in 0..<2 {
            bytes.append(contentsOf: [0x81, 0x01])
            bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        }
        bytes.append(0x00)
        XCTAssertThrowsError(try RunlistDecoder.decode(data: bytes)) { error in
            guard case NTFSError.corruptRunlist = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testRunReaderReadsAcrossRunsAndSparseHoles() throws {
        let disk = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let device = MemoryBlockDevice(data: disk)
        let runs = [
            DataRun(clusterCount: 1, startingLCN: 2),
            DataRun(clusterCount: 1, startingLCN: nil),
            DataRun(clusterCount: 1, startingLCN: 0)
        ]

        let result = try RunReader.read(runs: runs, virtualOffset: 1000, length: 2000, clusterSize: 1024, device: device)

        var expected = disk.subdata(in: 3048..<3072)
        expected.append(Data(count: 1024))
        expected.append(disk.subdata(in: 0..<952))
        XCTAssertEqual(result, expected)
    }

    func testRunReaderRejectsInvalidRanges() {
        let device = MemoryBlockDevice(data: Data(count: 4096))
        let mapped = [DataRun(clusterCount: 3, startingLCN: 0)]

        XCTAssertThrowsError(try RunReader.read(runs: mapped, virtualOffset: 3000, length: 100, clusterSize: 1024, device: device), "past the mapped runs")
        XCTAssertThrowsError(try RunReader.read(runs: [DataRun(clusterCount: 1, startingLCN: 10)], virtualOffset: 0, length: 16, clusterSize: 1024, device: device), "run points outside the device")
        XCTAssertThrowsError(try RunReader.read(runs: [DataRun(clusterCount: UInt64.max, startingLCN: 0)], virtualOffset: 0, length: 16, clusterSize: 1024, device: device), "run size overflows")
        XCTAssertThrowsError(try RunReader.read(runs: mapped, virtualOffset: UInt64.max, length: 16, clusterSize: 1024, device: device), "offset overflows")
        XCTAssertThrowsError(try RunReader.read(runs: mapped, virtualOffset: 0, length: -1, clusterSize: 1024, device: device), "negative length")
        XCTAssertEqual(try RunReader.read(runs: mapped, virtualOffset: 0, length: 0, clusterSize: 1024, device: device), Data())
    }

    func testBlockDeviceRejectsRangesWithoutOverflow() {
        let device = MemoryBlockDevice(data: Data(count: 4096))
        XCTAssertThrowsError(try device.read(offset: UInt64.max, count: 16))
        XCTAssertThrowsError(try device.read(offset: 4090, count: 16))
        XCTAssertThrowsError(try device.read(offset: 0, count: -1))
        XCTAssertEqual(try device.read(offset: 4096, count: 0), Data())
    }

    // MARK: - Reading data

    func testReadDataRefusesCompressedAndEncryptedStreams() throws {
        let compressed = try Fixtures.patchedVolume(path: "/big.bin") { image, record, _, data in
            image[record + data + 12] |= 0x01  // compressed flag
        }
        XCTAssertThrowsError(try compressed.readFile(at: "/big.bin")) { error in
            guard case NTFSError.unsupported(.compression) = error else { return XCTFail("unexpected error \(error)") }
        }

        let encrypted = try Fixtures.patchedVolume(path: "/big.bin") { image, record, _, data in
            image[record + data + 13] |= 0x40  // encrypted flag
        }
        XCTAssertThrowsError(try encrypted.readFile(at: "/big.bin")) { error in
            guard case NTFSError.unsupported(.encryption) = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testReadDataRefusesBrokenAttributeListAndReparsePoints() throws {
        // Turn the first attribute ($STANDARD_INFORMATION) into an attribute list. Its bytes are not a
        // valid list, so the engine must report a corrupt list and must not return the file data.
        let withList = try Fixtures.patchedVolume(path: "/small.txt") { image, record, first, _ in
            image[record + first] = 0x20
        }
        XCTAssertThrowsError(try withList.readFile(at: "/small.txt")) { error in
            guard case NTFSError.corruptAttributeList = error else { return XCTFail("unexpected error \(error)") }
        }

        let withReparse = try Fixtures.patchedVolume(path: "/small.txt") { image, record, first, _ in
            image[record + first] = 0xC0
        }
        XCTAssertThrowsError(try withReparse.readFile(at: "/small.txt")) { error in
            guard case NTFSError.unsupported(.reparse) = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testReadDataReturnsZerosBeyondInitializedSize() throws {
        let reference = try NTFSVolume(blockDevice: MemoryBlockDevice(data: try Fixtures.miniImage())).readFile(at: "/big.bin")
        XCTAssertEqual(reference.count, 20_000)

        let volume = try Fixtures.patchedVolume(path: "/big.bin") { image, record, _, data in
            Fixtures.put64(&image, record + data + 0x38, 1000)  // initialized size
        }
        let data = try volume.readFile(at: "/big.bin")
        XCTAssertEqual(data.count, 20_000)
        XCTAssertEqual(data.prefix(1000), reference.prefix(1000))
        XCTAssertEqual(data.suffix(19_000), Data(count: 19_000))
    }

    func testReadDataRejectsSizesBeyondTheMappedRuns() throws {
        // A size larger than the runs map must fail before anything big is allocated.
        let unmapped = try Fixtures.patchedVolume(path: "/big.bin") { image, record, _, data in
            Fixtures.put64(&image, record + data + 0x30, 100_000_000)
            Fixtures.put64(&image, record + data + 0x38, 100_000_000)
        }
        XCTAssertThrowsError(try unmapped.readFile(at: "/big.bin")) { error in
            guard case NTFSError.outOfBounds = error else { return XCTFail("unexpected error \(error)") }
        }

        // An absurd size is refused by the limit.
        let huge = try Fixtures.patchedVolume(path: "/big.bin") { image, record, _, data in
            Fixtures.put64(&image, record + data + 0x30, 1 << 40)
            Fixtures.put64(&image, record + data + 0x38, 1 << 40)
        }
        XCTAssertThrowsError(try huge.readFile(at: "/big.bin")) { error in
            guard case NTFSError.resourceLimit = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    // MARK: - Mutation

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Flips bytes in the boot sector, in MFT records and in the index blocks of a valid image and walks the volume.
    /// An error is fine. A crash or a hang is not.
    func testMutatedMetadataNeverCrashes() throws {
        let image = try Fixtures.miniImage()
        let volume = try NTFSVolume(blockDevice: MemoryBlockDevice(data: image))
        let clusterSize = Int(volume.bootSector.clusterSizeBytes)

        var recordOffsets = (0..<24).map { Fixtures.diskOffset(ofRecord: UInt64($0), in: volume) }
        for path in ["/small.txt", "/big.bin", "/dir", "/many", "/unicode"] {
            let record = try volume.lookup(path: path).record
            recordOffsets.append(Fixtures.diskOffset(ofRecord: record.recordNumber, in: volume))
        }
        let many = try volume.lookup(path: "/many").record
        let indexRun = try XCTUnwrap(many.attribute(ofType: .indexAllocation, name: "$I30")?.runs?.first)
        let indexStart = Int(try XCTUnwrap(indexRun.startingLCN)) * clusterSize
        let indexLength = Int(indexRun.clusterCount) * clusterSize

        var rng = SplitMix64(state: 0xC0FFEE)
        for _ in 0..<3000 {
            var mutated = image
            for _ in 0..<(1 + Int(rng.next() % 6)) {
                let position: Int
                switch rng.next() % 10 {
                case 0..<3:
                    position = Int(rng.next() % 512)
                case 3..<8:
                    position = recordOffsets[Int(rng.next() % UInt64(recordOffsets.count))] + Int(rng.next() % 1024)
                default:
                    position = indexStart + Int(rng.next() % UInt64(indexLength))
                }
                mutated[position] = UInt8(truncatingIfNeeded: rng.next())
            }

            let broken = MemoryBlockDevice(data: mutated)
            guard let volume = try? NTFSVolume(blockDevice: broken) else { continue }
            _ = try? volume.listDirectory(at: "/")
            _ = try? volume.listDirectory(at: "/many")
            _ = try? volume.readFile(at: "/small.txt")
            _ = try? volume.readFile(at: "/big.bin")
            _ = try? volume.lookup(path: "/many/file-100-with-a-long-name-to-fill-index-blocks.txt")
            for number in 0..<24 {
                _ = try? volume.readMFTRecord(number: UInt64(number))
            }
        }
    }
}
