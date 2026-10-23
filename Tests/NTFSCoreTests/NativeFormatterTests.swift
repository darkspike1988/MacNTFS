import Foundation
import XCTest
@testable import NTFSCore

final class NativeFormatterTests: XCTestCase {
    func testSystemStreamsAndRootIndexAcrossClusterSizes() throws {
        for cluster: UInt32 in [1024, 4096, 65536] {
            let device = MemoryBlockDevice(data: Data(repeating: 0xa5, count: 20 * 1024 * 1024))
            try NTFSFormatter.format(device: device, options: .init(volumeName: "NATIVE", clusterSize: cluster))
            let volume = try NTFSVolume(blockDevice: device)
            XCTAssertTrue(try volume.readMFTRecord(number: 11).isDirectory)
            let log = try volume.readMFTRecord(number: 2)
            XCTAssertTrue(try XCTUnwrap(log.defaultDataAttribute).isNonResident)
            let journal = try volume.readData(record: log)
            XCTAssertEqual(journal.count, 2 * 1024 * 1024)
            XCTAssertEqual(journal.prefix(4), Data("RSTR".utf8))
            XCTAssertEqual(journal.subdata(in: 4096..<4100), Data("RSTR".utf8))
            XCTAssertTrue(journal.dropFirst(8192).allSatisfy { $0 == 0xff })
            XCTAssertEqual(try volume.readData(record: volume.readMFTRecord(number: 4)).count, 2560)
            XCTAssertEqual(try volume.readData(record: volume.readMFTRecord(number: 7)).prefix(11), try device.read(offset: 0, count: 11))
            let bad = try XCTUnwrap(volume.readMFTRecord(number: 8).attribute(ofType: .data, name: "$Bad"))
            XCTAssertTrue(try XCTUnwrap(bad.runs).allSatisfy(\.isSparse))
            let secure = try volume.readMFTRecord(number: 9)
            XCTAssertNotNil(secure.attribute(ofType: .indexRoot, name: "$SDH"))
            XCTAssertNotNil(secure.attribute(ofType: .indexRoot, name: "$SII"))
            let root = try volume.readMFTRecord(number: 5)
            XCTAssertNotNil(root.attribute(ofType: .indexAllocation, name: "$I30"))
            try volume.writeFile(fileName: "native-file.bin", data: Data(repeating: 0x79, count: 100_000))
            XCTAssertEqual(try volume.readFile(at: "/native-file.bin"), Data(repeating: 0x79, count: 100_000))
        }
    }

    func testIndependentCheckerFreshAndAfterWrites() throws {
        let checker = "/Library/Filesystems/tuxera_ntfs.fs/Contents/Resources/Support/10.9/ntfsck"
        guard FileManager.default.isExecutableFile(atPath: checker) else {
            throw XCTSkip("Optional independent NTFS checker is not installed")
        }
        for cluster: UInt32 in [1024, 4096, 65536] {
            try checkFormattedImage(cluster: cluster, checker: checker)
        }
    }

    private func checkFormattedImage(cluster: UInt32, checker: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-formatter-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()
        let device = try FileBlockDevice(path: url.path, writable: true)
        try NTFSFormatter.format(device: device, options: .init(clusterSize: cluster))
        func check() throws {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: checker)
            process.arguments = ["-s", "-P", url.path]
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        }
        try check()
        let volume = try NTFSVolume(blockDevice: device)
        for i in 0..<64 {
            let content = Data(repeating: UInt8(i), count: i % 2 == 0 ? 150 : 8193)
            try volume.writeFile(fileName: "roundtrip-\(i).bin", data: content)
            XCTAssertEqual(try volume.readFile(at: "/roundtrip-\(i).bin"), content)
        }
        try device.flush()
        try check()
    }
}
