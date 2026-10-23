import Foundation
import XCTest
@testable import NTFSCore

final class FormatterInteropTests: XCTestCase {
    func testUpCaseTableIsCompleteAndAllocated() throws {
        let device = MemoryBlockDevice(data: Data(repeating: 0, count: 20 * 1024 * 1024))
        try NTFSFormatter.format(device: device)
        let volume = try NTFSVolume(blockDevice: device)
        let record = try volume.readMFTRecord(number: 10)
        let table = try volume.readData(record: record)
        XCTAssertEqual(table.count, 128 * 1024)
        func mapping(_ unit: UInt16) -> UInt16 {
            let offset = Int(unit) * 2
            return UInt16(table[offset]) | UInt16(table[offset + 1]) << 8
        }
        XCTAssertEqual(mapping(0x0061), 0x0041)
        XCTAssertEqual(mapping(0x00E4), 0x00C4)
        XCTAssertEqual(mapping(0x03C3), 0x03A3)
        XCTAssertEqual(mapping(0x00DF), 0x00DF, "Expanding uppercase mappings retain their code unit")
        XCTAssertEqual(mapping(0xD800), 0xD800, "Surrogate code units retain their identity")

        let bitmap = try volume.readData(record: volume.readMFTRecord(number: 6))
        // Default geometry places the complete 32-cluster table at clusters 40...71.
        for cluster in 40..<72 {
            XCTAssertNotEqual(bitmap[cluster / 8] & UInt8(1 << (cluster % 8)), 0)
        }
    }

    func testNonASCIIUppercaseDuplicateIsRejectedWithoutMutation() throws {
        let device = MemoryBlockDevice(data: Data(repeating: 0, count: 20 * 1024 * 1024))
        try NTFSFormatter.format(device: device)
        let volume = try NTFSVolume(blockDevice: device)
        try volume.writeFile(fileName: "äpfel.txt", data: Data("original".utf8))
        let before = try device.read(offset: 0, count: Int(device.size))
        XCTAssertThrowsError(try volume.writeFile(fileName: "ÄPFEL.TXT", data: Data("replacement".utf8)))
        XCTAssertEqual(try device.read(offset: 0, count: Int(device.size)), before)
        let reopened = try NTFSVolume(blockDevice: device)
        XCTAssertEqual(try reopened.readFile(at: "/ÄPFEL.TXT"), Data("original".utf8))
    }
}
