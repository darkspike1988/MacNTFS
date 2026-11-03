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
