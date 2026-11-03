import XCTest
@testable import NTFSCore

/// LZNT1 vectors worked out by hand from the format: a 2-byte chunk header (bit 15 compressed,
/// bits 14 to 12 = 3, low 12 bits = chunk data size - 1), then groups of one flag byte and 8 items.
final class LZNT1Tests: XCTestCase {

    func testLiteralsOnly() throws {
        // data: flag 0x00 + 8 literals = 9 bytes -> header 0xB000 | 8
        let input = Data([0x08, 0xB0, 0x00] + Array("abcdefgh".utf8))
        XCTAssertEqual(try LZNT1.decompress(input, maxOutput: 4096), Data("abcdefgh".utf8))
    }

    func testBackReference() throws {
        // a b c, then a match of length 6 at distance 3: token = (3-1) << 12 | (6-3) = 0x2003, flag bit 3
        let input = Data([0x05, 0xB0, 0x08, 0x61, 0x62, 0x63, 0x03, 0x20])
        XCTAssertEqual(try LZNT1.decompress(input, maxOutput: 4096), Data("abcabcabc".utf8))
    }

    func testOverlappingBackReferenceRepeatsTheByte() throws {
        // 'a', then length 7 at distance 1: token = 0 << 12 | (7-3) = 4, flag bit 1
        let input = Data([0x03, 0xB0, 0x02, 0x61, 0x04, 0x00])
        XCTAssertEqual(try LZNT1.decompress(input, maxOutput: 4096), Data(repeating: 0x61, count: 8))
    }

    func testUncompressedChunkAndTwoChunks() throws {
        let raw = Data((0..<4096).map { UInt8($0 & 0xFF) })
        var input = Data([0xFF, 0x3F])  // 0x3000 | 4095: not compressed, 4096 bytes
        input.append(raw)
        input.append(contentsOf: [0x08, 0xB0, 0x00] + Array("abcdefgh".utf8))
        input.append(contentsOf: [0x00, 0x00])  // end of the stream
        input.append(contentsOf: [0xAA, 0xBB])  // ignored after the end

        let output = try LZNT1.decompress(input, maxOutput: 8192)

        XCTAssertEqual(output.count, 4096 + 8)
        XCTAssertEqual(output.prefix(4096), raw)
        XCTAssertEqual(output.suffix(8), Data("abcdefgh".utf8))
    }

    func testBackReferenceBitSplitGrowsWithTheChunk() throws {
        // After 32 bytes of literals the offset needs 5 bits, so the length field has 11 bits.
        // Match: distance 20, length 40 -> token = (19 << 11) | (40 - 3)
        let literals = Array(0..<32).map { UInt8($0 + 0x41) }
        var chunk: [UInt8] = []
        for group in 0..<4 {
            chunk.append(0x00)
            chunk.append(contentsOf: literals[(group * 8)..<(group * 8 + 8)])
        }
        let token = (19 << 11) | (40 - 3)
        chunk.append(0x01)  // first item of the group is a match
        chunk.append(UInt8(token & 0xFF))
        chunk.append(UInt8(token >> 8))
        let header = 0xB000 | (chunk.count - 1)
        let input = Data([UInt8(header & 0xFF), UInt8(header >> 8)] + chunk)

        var expected = literals
        for _ in 0..<40 { expected.append(expected[expected.count - 20]) }
        XCTAssertEqual(try LZNT1.decompress(input, maxOutput: 4096), Data(expected))
    }

    func testRejectsDamagedStreams() {
        XCTAssertThrowsError(try LZNT1.decompress(Data([0x05, 0x10, 0, 0, 0, 0, 0, 0]), maxOutput: 4096), "wrong signature")
        XCTAssertThrowsError(try LZNT1.decompress(Data([0xFF, 0xB0, 0x00]), maxOutput: 4096), "chunk runs past the data")
        XCTAssertThrowsError(try LZNT1.decompress(Data([0x03, 0xB0, 0x01, 0x03, 0x20]), maxOutput: 4096), "back reference at the start")
        XCTAssertThrowsError(try LZNT1.decompress(Data([0x04, 0xB0, 0x02, 0x61, 0xFF, 0xFF]), maxOutput: 4096), "distance beyond the written bytes")
        XCTAssertThrowsError(try LZNT1.decompress(Data([0x08, 0xB0, 0x00] + Array("abcdefgh".utf8)), maxOutput: 4), "output limit")
        XCTAssertThrowsError(try LZNT1.decompress(Data([0x04, 0xB0, 0x02, 0x61, 0x03]), maxOutput: 4096), "back reference cut off")
    }

    func testEmptyInputGivesEmptyOutput() throws {
        XCTAssertEqual(try LZNT1.decompress(Data(), maxOutput: 10), Data())
        XCTAssertEqual(try LZNT1.decompress(Data([0, 0]), maxOutput: 10), Data())
    }
}
