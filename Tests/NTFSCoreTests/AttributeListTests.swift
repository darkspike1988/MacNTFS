import XCTest
@testable import NTFSCore

final class AttributeListTests: XCTestCase {

    /// One `$ATTRIBUTE_LIST` entry as NTFS stores it, padded to 8 bytes.
    private func listEntry(type: UInt32, startingVCN: UInt64 = 0, record: UInt64, id: UInt16, name: String? = nil) -> Data {
        let units = Array((name ?? "").utf16)
        let length = (0x1A + units.count * 2 + 7) & ~7
        var data = Data(count: length)
        func put(_ value: UInt64, at offset: Int, bytes: Int) {
            for i in 0..<bytes { data[offset + i] = UInt8((value >> UInt64(8 * i)) & 0xFF) }
        }
        put(UInt64(type), at: 0, bytes: 4)
        put(UInt64(length), at: 4, bytes: 2)
        data[6] = UInt8(units.count)
        data[7] = 0x1A
        put(startingVCN, at: 8, bytes: 8)
        put(record | (7 << 48), at: 0x10, bytes: 8)  // sequence number 7 in the top bits
        put(UInt64(id), at: 0x18, bytes: 2)
        for (i, unit) in units.enumerated() { put(UInt64(unit), at: 0x1A + i * 2, bytes: 2) }
        return data
    }

    private func attribute(type: UInt32, name: String? = nil, startingVCN: UInt64, runs: [DataRun], real: UInt64 = 0) -> NTFSAttribute {
        // Wrapping arithmetic: the overflow test uses sizes that overflow on purpose.
        let clusters = runs.reduce(UInt64(0)) { $0 &+ $1.clusterCount }
        return NTFSAttribute(
            type: AttributeType(rawValue: type),
            recordLength: 0x48,
            isNonResident: true,
            name: name,
            flags: [],
            attributeID: 3,
            payload: .nonResident(
                startingVCN: startingVCN,
                endingVCN: startingVCN &+ clusters &- 1,
                allocatedSize: clusters &* 4096,
                realSize: real,
                initializedSize: real,
                runs: runs
            )
        )
    }

    // MARK: - Parser

    func testParsesEntriesNamesAndRecordNumbers() throws {
        var list = listEntry(type: 0x10, record: 40, id: 0)
        list.append(listEntry(type: 0xA0, startingVCN: 144, record: 2805, id: 5, name: "$I30"))
        list.append(Data(count: 24))  // padding after the last entry

        let entries = try AttributeListParser.parse(list)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].type, .standardInformation)
        XCTAssertEqual(entries[0].recordNumber, 40)
        XCTAssertNil(entries[0].name)
        XCTAssertEqual(entries[1].type, .indexAllocation)
        XCTAssertEqual(entries[1].name, "$I30")
        XCTAssertEqual(entries[1].startingVCN, 144)
        XCTAssertEqual(entries[1].recordNumber, 2805, "the sequence number in the top 16 bits must not leak into the record number")
        XCTAssertEqual(entries[1].attributeID, 5)
    }

    func testRejectsMalformedEntries() {
        var tooLong = listEntry(type: 0x80, record: 40, id: 1)
        tooLong[4] = 0xF0  // length 240, but only 32 bytes of data
        XCTAssertThrowsError(try AttributeListParser.parse(tooLong))

        var tooShort = listEntry(type: 0x80, record: 40, id: 1)
        tooShort[4] = 0x08  // shorter than the fixed header
        XCTAssertThrowsError(try AttributeListParser.parse(tooShort))

        var nameOutside = listEntry(type: 0x80, record: 40, id: 1, name: "abc")
        nameOutside[6] = 40  // name longer than the entry
        XCTAssertThrowsError(try AttributeListParser.parse(nameOutside))
    }

    func testEmptyAndZeroPaddedListsParse() throws {
        XCTAssertEqual(try AttributeListParser.parse(Data()).count, 0)
        XCTAssertEqual(try AttributeListParser.parse(Data(count: 64)).count, 0)
    }

    // MARK: - Merging extents

    func testMergesExtentsInVCNOrderAndKeepsSizesOfTheFirst() throws {
        let second = attribute(type: 0xA0, name: "$I30", startingVCN: 4, runs: [DataRun(clusterCount: 2, startingLCN: 90)], real: 0)
        let first = attribute(type: 0xA0, name: "$I30", startingVCN: 0, runs: [DataRun(clusterCount: 4, startingLCN: 10)], real: 24_576)
        let other = attribute(type: 0x80, startingVCN: 0, runs: [DataRun(clusterCount: 1, startingLCN: 500)], real: 100)

        let merged = try AttributeMerger.merge([second, other, first])

        XCTAssertEqual(merged.count, 2, "two extents of one attribute become one")
        let index = try XCTUnwrap(merged.first { $0.type == .indexAllocation })
        XCTAssertEqual(index.runs, [DataRun(clusterCount: 4, startingLCN: 10), DataRun(clusterCount: 2, startingLCN: 90)])
        XCTAssertEqual(index.realDataSize, 24_576)
        XCTAssertEqual(index.startingVCN, 0)
    }

    func testMergeRejectsGapsAndMissingFirstExtent() {
        let first = attribute(type: 0x80, startingVCN: 0, runs: [DataRun(clusterCount: 4, startingLCN: 10)])
        let afterGap = attribute(type: 0x80, startingVCN: 9, runs: [DataRun(clusterCount: 1, startingLCN: 50)])
        XCTAssertThrowsError(try AttributeMerger.merge([first, afterGap]), "gap between extents")

        let overlapping = attribute(type: 0x80, startingVCN: 2, runs: [DataRun(clusterCount: 1, startingLCN: 50)])
        XCTAssertThrowsError(try AttributeMerger.merge([first, overlapping]), "overlapping extents")

        let lateOnly = attribute(type: 0x80, startingVCN: 4, runs: [DataRun(clusterCount: 1, startingLCN: 50)])
        XCTAssertThrowsError(try AttributeMerger.merge([lateOnly, attribute(type: 0x80, startingVCN: 8, runs: [DataRun(clusterCount: 1, startingLCN: 60)])]), "no extent starts at VCN 0")
    }

    func testMergeKeepsAttributesWithDifferentNamesApart() throws {
        let unnamed = attribute(type: 0x80, startingVCN: 0, runs: [DataRun(clusterCount: 1, startingLCN: 10)])
        let stream = attribute(type: 0x80, name: "stream", startingVCN: 0, runs: [DataRun(clusterCount: 1, startingLCN: 20)])
        XCTAssertEqual(try AttributeMerger.merge([unnamed, stream]).count, 2)
    }

    func testMergeRejectsRunListsThatOverflow() {
        let first = attribute(type: 0x80, startingVCN: 0, runs: [DataRun(clusterCount: UInt64.max - 1, startingLCN: 10)])
        let second = attribute(type: 0x80, startingVCN: UInt64.max - 1, runs: [DataRun(clusterCount: 5, startingLCN: 50)])
        XCTAssertThrowsError(try AttributeMerger.merge([first, second]))
    }
}

// MARK: - Extension records of a real volume

final class ExtensionRecordTests: XCTestCase {

    private struct FragmentedFile {
        let image: Data
        let base: UInt64
        /// Numbers of the extension records the attribute list names.
        let extensions: [UInt64]
        /// Where the bytes of the attribute list value are on the device.
        let listValueOffset: Int
        let volume: NTFSVolume
    }

    /// `/frag/f0.bin` of mini-attrlist: a file whose data runs are spread over extension records.
    private func fragmentedFile() throws -> FragmentedFile {
        let image = try Fixtures.miniAttributeListImage()
        let volume = try NTFSVolume(blockDevice: MemoryBlockDevice(data: image))
        let resolved = try volume.lookup(path: "/frag/f0.bin").record
        let base = resolved.recordNumber
        let list = try XCTUnwrap(resolved.attribute(ofType: .attributeList))
        let value = try NTFSVolume.attributeValue(list, bootSector: volume.bootSector, device: volume.blockDevice)
        let extensions = Set(try AttributeListParser.parse(value).map(\.recordNumber).filter { $0 != base }).sorted()
        XCTAssertFalse(extensions.isEmpty, "f0.bin must have extension records")

        let valueOffset: Int
        if let residentValue = list.residentData {
            // Resident: the value is inside the record. Find it by its bytes.
            let recordOffset = Fixtures.diskOffset(ofRecord: base, in: volume)
            let record = image.subdata(in: recordOffset..<(recordOffset + 1024))
            let range = try XCTUnwrap(record.range(of: residentValue))
            valueOffset = recordOffset + range.lowerBound
        } else {
            let run = try XCTUnwrap(list.runs?.first)
            valueOffset = Int(try XCTUnwrap(run.startingLCN)) * Int(volume.bootSector.clusterSizeBytes)
        }
        return FragmentedFile(image: image, base: base, extensions: extensions, listValueOffset: valueOffset, volume: volume)
    }

    func testIntactFragmentedFileReads() throws {
        let file = try fragmentedFile()
        XCTAssertGreaterThan(try file.volume.readFile(at: "/frag/f0.bin").count, 0)
    }

    func testExtensionRecordThatBelongsToAnotherRecordIsRejected() throws {
        let file = try fragmentedFile()
        var image = file.image
        let extensionOffset = Fixtures.diskOffset(ofRecord: file.extensions[0], in: file.volume)
        image[extensionOffset + 0x20] = 0x63  // base record reference: another record

        let broken = try NTFSVolume(blockDevice: MemoryBlockDevice(data: image))
        XCTAssertThrowsError(try broken.readFile(at: "/frag/f0.bin")) { error in
            guard case NTFSError.corruptAttributeList = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testExtensionRecordThatIsNotInUseIsRejected() throws {
        let file = try fragmentedFile()
        var image = file.image
        let extensionOffset = Fixtures.diskOffset(ofRecord: file.extensions[0], in: file.volume)
        image[extensionOffset + 0x16] &= ~0x01

        let broken = try NTFSVolume(blockDevice: MemoryBlockDevice(data: image))
        XCTAssertThrowsError(try broken.readFile(at: "/frag/f0.bin")) { error in
            guard case NTFSError.corruptAttributeList = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testListEntryThatPointsToAnOrdinaryRecordIsRejected() throws {
        // An ordinary file record has the base reference 0, so it is no extension of any file. Point the first
        // entry that names an extension record at the root directory (record 5).
        let file = try fragmentedFile()
        var image = file.image
        var entry = file.listValueOffset
        var patched = false
        for _ in 0..<64 {
            let length = Int(image[entry + 4]) | (Int(image[entry + 5]) << 8)
            guard length >= 0x1A else { break }
            let number = (0..<6).reduce(UInt64(0)) { $0 | (UInt64(image[entry + 0x10 + $1]) << UInt64(8 * $1)) }
            if number != file.base {
                image[entry + 0x10] = 5
                for i in 1..<6 { image[entry + 0x10 + i] = 0 }
                patched = true
                break
            }
            entry += length
        }
        XCTAssertTrue(patched)

        let broken = try NTFSVolume(blockDevice: MemoryBlockDevice(data: image))
        XCTAssertThrowsError(try broken.readFile(at: "/frag/f0.bin")) { error in
            guard case NTFSError.corruptAttributeList = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testMftWithADamagedListIsReportedAsDamaged() throws {
        // Turn the first attribute of record 0 ($MFT) into an attribute list and give its value an entry
        // that is longer than the value.
        var image = try Fixtures.miniImage()
        let boot = try BootSector(data: image.prefix(512))
        let recordOffset = Int(boot.mftByteOffset)
        let first = Int(image[recordOffset + 0x14]) | (Int(image[recordOffset + 0x15]) << 8)
        image[recordOffset + first] = 0x20
        let valueOffset = Int(image[recordOffset + first + 0x14]) | (Int(image[recordOffset + first + 0x15]) << 8)
        image[recordOffset + first + valueOffset + 4] = 0xF0
        image[recordOffset + first + valueOffset + 5] = 0x00

        XCTAssertThrowsError(try NTFSVolume(blockDevice: MemoryBlockDevice(data: image))) { error in
            // A damaged list is reported as damaged, not as a missing feature.
            guard case NTFSError.corruptAttributeList = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testExtentsThatDoNotReachTheEndOfTheAttributeAreRejected() throws {
        // Two extents cover VCN 0 to 4, but the last one says the attribute ends at VCN 9: a part is missing.
        func extent(start: UInt64, end: UInt64, clusters: UInt64) -> NTFSAttribute {
            NTFSAttribute(
                type: .data, recordLength: 0x48, isNonResident: true, name: nil, flags: [], attributeID: 1,
                payload: .nonResident(
                    startingVCN: start, endingVCN: end, allocatedSize: 40_960, realSize: 40_960, initializedSize: 40_960,
                    runs: [DataRun(clusterCount: clusters, startingLCN: 100 + start)]
                )
            )
        }
        XCTAssertThrowsError(try AttributeMerger.merge([extent(start: 0, end: 2, clusters: 3), extent(start: 3, end: 9, clusters: 2)])) { error in
            guard case NTFSError.corruptAttributeList = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertNoThrow(try AttributeMerger.merge([extent(start: 0, end: 2, clusters: 3), extent(start: 3, end: 4, clusters: 2)]))
    }
}
