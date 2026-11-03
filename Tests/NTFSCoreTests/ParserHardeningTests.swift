import XCTest
@testable import NTFSCore

/// Checks that hostile or damaged input produces an error or correct data, never a crash or wrong bytes.
final class ParserHardeningTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The fixtures use the experimental formatter and writer.
        setenv(ExperimentalGate.environmentKey, "1", 1)
    }

    private func formattedDevice(megabytes: Int = 12) throws -> MemoryBlockDevice {
        let device = MemoryBlockDevice(data: Data(repeating: 0, count: megabytes * 1024 * 1024), writable: true)
        try NTFSFormatter.format(device: device, options: .init(volumeName: "HARDEN"))
        return device
    }

    // MARK: - Boot sector

    func testBootSectorRejectsHostileValues() throws {
        let device = try formattedDevice()
        let valid = try device.read(offset: 0, count: 512)
        XCTAssertNoThrow(try BootSector(data: valid))

        func mutated(_ patch: (inout Data) -> Void) -> Data {
            var copy = valid
            patch(&copy)
            return copy
        }
        func put64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
            for i in 0..<8 { data[offset + i] = UInt8((value >> UInt64(8 * i)) & 0xFF) }
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
            ("total sectors UInt64.max", mutated { put64(&$0, 0x28, UInt64.max) }),
            ("total sectors 0", mutated { put64(&$0, 0x28, 0) }),
            ("MFT cluster UInt64.max", mutated { put64(&$0, 0x30, UInt64.max) })
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

        try FixupApplier.applyFixup(data: &record, updateSequenceOffset: usaOffset, updateSequenceSize: blocks + 1, bytesPerSector: 4096)

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
        let device = MemoryBlockDevice(data: disk, writable: false)
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
        let device = MemoryBlockDevice(data: Data(count: 4096), writable: false)
        let mapped = [DataRun(clusterCount: 3, startingLCN: 0)]

        XCTAssertThrowsError(try RunReader.read(runs: mapped, virtualOffset: 3000, length: 100, clusterSize: 1024, device: device), "past the mapped runs")
        XCTAssertThrowsError(try RunReader.read(runs: [DataRun(clusterCount: 1, startingLCN: 10)], virtualOffset: 0, length: 16, clusterSize: 1024, device: device), "run points outside the device")
        XCTAssertThrowsError(try RunReader.read(runs: [DataRun(clusterCount: UInt64.max, startingLCN: 0)], virtualOffset: 0, length: 16, clusterSize: 1024, device: device), "run size overflows")
        XCTAssertThrowsError(try RunReader.read(runs: mapped, virtualOffset: UInt64.max, length: 16, clusterSize: 1024, device: device), "offset overflows")
        XCTAssertThrowsError(try RunReader.read(runs: mapped, virtualOffset: 0, length: -1, clusterSize: 1024, device: device), "negative length")
        XCTAssertEqual(try RunReader.read(runs: mapped, virtualOffset: 0, length: 0, clusterSize: 1024, device: device), Data())
    }

    // MARK: - Reading data

    /// Builds a file record and lets a test patch the raw bytes of the record and of its $DATA attribute.
    private func fileRecord(
        content: Data,
        runs: [DataRun]? = nil,
        patch: (inout Data, _ dataAttributeOffset: Int) -> Void = { _, _ in }
    ) throws -> MFTRecord {
        var raw = try MFTRecordBuilder.buildFileRecord(
            recordNumber: 40,
            parentDirectoryRecordNumber: 5,
            fileName: "fixture.bin",
            fileContent: content,
            dataRuns: runs,
            clusterSize: 4096
        )
        var offset = Int(raw[0x14]) | (Int(raw[0x15]) << 8)
        var dataOffset = -1
        while offset + 8 <= raw.count {
            let type = UInt32(raw[offset]) | (UInt32(raw[offset + 1]) << 8) | (UInt32(raw[offset + 2]) << 16) | (UInt32(raw[offset + 3]) << 24)
            if type == 0xFFFF_FFFF { break }
            let length = Int(raw[offset + 4]) | (Int(raw[offset + 5]) << 8)
            if type == 0x80 { dataOffset = offset; break }
            guard length > 0 else { break }
            offset += length
        }
        XCTAssertGreaterThan(dataOffset, 0, "fixture has no $DATA attribute")
        patch(&raw, dataOffset)
        return try MFTRecord(recordNumber: 40, rawData: raw)
    }

    private func put64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        for i in 0..<8 { data[offset + i] = UInt8((value >> UInt64(8 * i)) & 0xFF) }
    }

    func testReadDataRefusesCompressedAndEncryptedStreams() throws {
        let volume = try NTFSVolume(blockDevice: try formattedDevice())
        let content = Data("payload".utf8)

        let compressed = try fileRecord(content: content) { raw, dataOffset in raw[dataOffset + 12] = 0x01 }
        XCTAssertThrowsError(try volume.readData(record: compressed)) { error in
            guard case NTFSError.unsupported(.compression) = error else { return XCTFail("unexpected error \(error)") }
        }

        let encrypted = try fileRecord(content: content) { raw, dataOffset in raw[dataOffset + 13] = 0x40 }
        XCTAssertThrowsError(try volume.readData(record: encrypted)) { error in
            guard case NTFSError.unsupported(.encryption) = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testReadDataRefusesAttributeListAndReparsePoints() throws {
        let volume = try NTFSVolume(blockDevice: try formattedDevice())
        let content = Data("payload".utf8)

        // Turn the first attribute ($STANDARD_INFORMATION) into another type.
        let withList = try fileRecord(content: content) { raw, _ in
            let first = Int(raw[0x14]) | (Int(raw[0x15]) << 8)
            raw[first] = 0x20
        }
        XCTAssertThrowsError(try volume.readData(record: withList)) { error in
            guard case NTFSError.unsupported(.attributeList) = error else { return XCTFail("unexpected error \(error)") }
        }

        let withReparse = try fileRecord(content: content) { raw, _ in
            let first = Int(raw[0x14]) | (Int(raw[0x15]) << 8)
            raw[first] = 0xC0
        }
        XCTAssertThrowsError(try volume.readData(record: withReparse)) { error in
            guard case NTFSError.unsupported(.reparse) = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testReadDataReturnsZerosBeyondInitializedSize() throws {
        let device = try formattedDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let cluster = 3000  // free area near the end of the 12 MiB test volume
        try device.write(offset: UInt64(cluster * 4096), data: Data(repeating: 0xAB, count: 4096))

        let record = try fileRecord(content: Data(count: 4000), runs: [DataRun(clusterCount: 1, startingLCN: UInt64(cluster))]) { raw, dataOffset in
            put64(&raw, dataOffset + 0x38, 1000)  // initialized size
        }

        let data = try volume.readData(record: record)
        XCTAssertEqual(data.count, 4000)
        XCTAssertEqual(data.prefix(1000), Data(repeating: 0xAB, count: 1000))
        XCTAssertEqual(data.suffix(3000), Data(count: 3000))
    }

    func testReadDataRejectsSizesBeyondTheMappedRuns() throws {
        let device = try formattedDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let runs = [DataRun(clusterCount: 1, startingLCN: 3000)]

        // A size larger than the runs map must fail before anything big is allocated.
        let unmapped = try fileRecord(content: Data(count: 4000), runs: runs) { raw, dataOffset in
            put64(&raw, dataOffset + 0x30, 100_000)
            put64(&raw, dataOffset + 0x38, 100_000)
        }
        XCTAssertThrowsError(try volume.readData(record: unmapped)) { error in
            guard case NTFSError.outOfBounds = error else { return XCTFail("unexpected error \(error)") }
        }

        // An absurd size is refused by the limit.
        let huge = try fileRecord(content: Data(count: 4000), runs: runs) { raw, dataOffset in
            put64(&raw, dataOffset + 0x30, 1 << 40)
            put64(&raw, dataOffset + 0x38, 1 << 40)
        }
        XCTAssertThrowsError(try volume.readData(record: huge)) { error in
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

    /// Flips bytes in the boot sector and in the first MFT records of a valid image and walks the volume.
    /// An error is fine. A crash or a hang is not.
    func testMutatedMetadataNeverCrashes() throws {
        let device = try formattedDevice()
        let volume = try NTFSVolume(blockDevice: device)
        _ = try volume.writeFile(fileName: "small.txt", data: Data("hello".utf8))
        _ = try volume.writeFile(fileName: "big.bin", data: Data((0..<20_000).map { UInt8($0 & 0xFF) }))
        let image = try device.read(offset: 0, count: Int(device.size))

        var rng = SplitMix64(state: 0xC0FFEE)
        let mftOffset = 4 * 4096
        for _ in 0..<4000 {
            var mutated = image
            for _ in 0..<(1 + Int(rng.next() % 6)) {
                let position: Int
                if rng.next() % 5 < 2 {
                    position = Int(rng.next() % 512)
                } else {
                    let record = Int(rng.next() % 24)
                    position = mftOffset + record * 1024 + Int(rng.next() % 1024)
                }
                mutated[position] = UInt8(truncatingIfNeeded: rng.next())
            }

            let broken = MemoryBlockDevice(data: mutated, writable: false)
            guard let volume = try? NTFSVolume(blockDevice: broken) else { continue }
            _ = try? volume.listDirectory(at: "/")
            _ = try? volume.readFile(at: "/small.txt")
            _ = try? volume.readFile(at: "/big.bin")
            for number in 0..<24 {
                _ = try? volume.readMFTRecord(number: UInt64(number))
            }
        }
    }
}
