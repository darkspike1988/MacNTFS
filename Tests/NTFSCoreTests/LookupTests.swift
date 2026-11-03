import XCTest
@testable import NTFSCore

/// Name lookup on the committed mini image: exact UTF-16 match first, then the volume's $UpCase table.
final class LookupTests: XCTestCase {

    private func miniVolume() throws -> NTFSVolume {
        try NTFSVolume(blockDevice: MemoryBlockDevice(data: try Fixtures.miniImage()))
    }

    func testCaseIsIgnoredWithTheVolumeTable() throws {
        let volume = try miniVolume()
        XCTAssertEqual(try volume.readFile(at: "/DIR/NESTED.TXT").count, 700)
        XCTAssertEqual(try volume.readFile(at: "/Dir/Nested.Txt").count, 700)
        // 'é' (U+00E9) upper-cases to 'É' (U+00C9) in the table, so this finds the precomposed name.
        XCTAssertEqual(try volume.readFile(at: "/UNICODE/CAFÉ.TXT").count, 600)
    }

    func testCombiningCharactersAreNotNormalized() throws {
        let volume = try miniVolume()
        // "e" followed by U+0301 is a different name than "é". The volume has both files.
        XCTAssertEqual(try volume.readFile(at: "/unicode/cafe\u{301}.txt").count, 650)
        XCTAssertEqual(try volume.readFile(at: "/unicode/caf\u{E9}.txt").count, 600)
        // Ignoring case still must not merge them.
        XCTAssertEqual(try volume.readFile(at: "/UNICODE/CAFE\u{301}.TXT").count, 650)
    }

    func testMissingNamesAreReported() throws {
        let volume = try miniVolume()
        XCTAssertThrowsError(try volume.readFile(at: "/unicode/cafe.txt")) { error in
            guard case NTFSError.pathNotFound = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertThrowsError(try volume.readFile(at: "/small.txt/inside")) { error in
            guard case NTFSError.notADirectory = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testUpCaseTableNeedsTheFullSize() {
        XCTAssertNil(UpCaseTable(data: Data(count: 100)))
        var identity = Data(count: UpCaseTable.byteCount)
        for unit in 0..<65_536 {
            identity[unit * 2] = UInt8(unit & 0xFF)
            identity[unit * 2 + 1] = UInt8(unit >> 8)
        }
        let table = UpCaseTable(data: identity)
        XCTAssertEqual(table?.fold(0x41), 0x41)
        XCTAssertEqual(table?.fold([0x61, 0x62]), [0x61, 0x62])
    }
}
