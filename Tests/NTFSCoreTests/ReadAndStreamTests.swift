import CryptoKit
import Foundation
import XCTest
@testable import NTFSCore

/// Counts bytes written, to prove that stream changes cost the changed bytes only.
private final class CountingDevice: BlockDevice, @unchecked Sendable {
    let base: MemoryBlockDevice
    var written = 0
    init(_ base: MemoryBlockDevice) { self.base = base }
    var size: UInt64 { base.size }
    var isWritable: Bool { base.isWritable }
    func read(offset: UInt64, count: Int) throws -> Data { try base.read(offset: offset, count: count) }
    func write(offset: UInt64, data: Data) throws { written += data.count; try base.write(offset: offset, data: data) }
    func flush() throws { try base.flush() }
}

final class ReadAndStreamTests: XCTestCase {
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 24 MiB image written by Tuxera NTFS 27.0.1 (NTFS-3G based): an LZNT1-compressed
    /// file in a compressed directory, and a file fragmented into enough runs that its
    /// $DATA lives in extension records listed by $ATTRIBUTE_LIST.
    private func tuxeraFixture(writable: Bool = false) throws -> MemoryBlockDevice {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tuxera-features.img", withExtension: "lzfse",
                                                  subdirectory: "Fixtures"))
        let image = try NSData(contentsOf: url).decompressed(using: .lzfse) as Data
        return MemoryBlockDevice(data: image, writable: writable)
    }

    func testCompressedAndAttributeListFilesMatchIndependentDriver() throws {
        let volume = try NTFSVolume(blockDevice: tuxeraFixture())
        let words = try volume.readFile(at: "/comp/words.txt")
        XCTAssertEqual(words.count, 228_683)
        XCTAssertEqual(sha256(words), "b638d6694b8aa031bc69b64da3eb10994c8352cbae1b7adc9f701139576145f9")
        let compressed = try XCTUnwrap(volume.lookup(path: "/comp/words.txt").record.defaultDataAttribute)
        XCTAssertTrue(compressed.flags.contains(.compressed))

        let fragmented = try volume.lookup(path: "/fragmented.bin").record
        XCTAssertNotNil(fragmented.attribute(ofType: .attributeList))
        let whole = try volume.readData(record: fragmented)
        XCTAssertEqual(sha256(whole), "0cedc1918fb1905f5299f4b8853343e748f6ea988599e209c91981ef74695295")
        XCTAssertEqual(try volume.dataSize(record: fragmented).size, UInt64(whole.count))
        for (offset, length) in [(0, 1), (4095, 2), (777_777, 70_000), (whole.count - 3, 3)] {
            let part = try volume.readData(record: fragmented, offset: UInt64(offset), length: length)
            XCTAssertEqual(part, whole.subdata(in: offset..<(offset + length)))
        }
        for (offset, length) in [(65_535, 3), (100_000, 50_000)] {
            let record = try volume.lookup(path: "/comp/words.txt").record
            XCTAssertEqual(try volume.readData(record: record, offset: UInt64(offset), length: length),
                           words.subdata(in: offset..<(offset + length)))
        }
    }

    func testWritersRefuseRecordsWithExtensionRecordsWithoutChangingDisk() throws {
        let device = try tuxeraFixture(writable: true)
        let volume = try NTFSVolume(blockDevice: device)
        let before = try device.read(offset: 0, count: Int(device.size))
        let number = try volume.lookup(path: "/fragmented.bin").record.recordNumber
        XCTAssertThrowsError(try volume.writeData(recordNumber: number, offset: 0, data: Data([1])))
        XCTAssertThrowsError(try volume.truncate(recordNumber: number, size: 10))
        XCTAssertEqual(try device.read(offset: 0, count: Int(device.size)), before)
    }

    func testLZNT1BackReferencesPaddingAndCorruption() throws {
        // "abc" as literals, then one token: displacement 3, length 9.
        let stream: [UInt8] = [0x05, 0xB0, 0x08, 0x61, 0x62, 0x63, 0x06, 0x20, 0x00, 0x00]
        XCTAssertEqual(try NTFSCompression.decompressLZNT1(stream[...], outputSize: 12), Array("abcabcabcabc".utf8))
        let padded = try NTFSCompression.decompressLZNT1(stream[...], outputSize: 8192)
        XCTAssertEqual(Array(padded.prefix(12)), Array("abcabcabcabc".utf8))
        XCTAssertTrue(padded.dropFirst(12).allSatisfy { $0 == 0 })
        let corrupt: [UInt8] = [0x03, 0xB0, 0x01, 0x06, 0x20, 0x00]
        XCTAssertThrowsError(try NTFSCompression.decompressLZNT1(corrupt[...], outputSize: 16))
    }

    func testJournalStateGatesWritesAndCleanJournalIsLeftUntouched() throws {
        let device = MemoryBlockDevice(data: Data(count: 32 << 20))
        try NTFSFormatter.format(device: device, options: .init(volumeName: "JOURNAL"))
        let volume = try NTFSVolume(blockDevice: device)
        XCTAssertEqual(try volume.journalState(), .clean)
        let log = try volume.readMFTRecord(number: 2)
        let journal = try volume.readData(record: log)
        try volume.writeFile(fileName: "a.txt", data: Data("a".utf8))
        XCTAssertEqual(try NTFSVolume(blockDevice: device).readData(record: log), journal)

        // Mark both restart areas as having an active client and no clean shutdown.
        let cluster = UInt64(volume.bootSector.clusterSizeBytes)
        let start = try XCTUnwrap(log.defaultDataAttribute?.runs?.first?.startingLCN) * cluster
        for page in [UInt64(0), 4096] {
            var bytes = try device.read(offset: start + page, count: 4096)
            try FixupApplier.applyFixup(data: &bytes, updateSequenceOffset: Int(NTFSVolumeWriter.u16(bytes, 4)),
                                        updateSequenceSize: Int(NTFSVolumeWriter.u16(bytes, 6)), bytesPerSector: 512)
            let area = Int(NTFSVolumeWriter.u16(bytes, 24))
            NTFSVolumeWriter.put(UInt16(0), into: &bytes, at: area + 12)
            NTFSVolumeWriter.put(UInt16(0), into: &bytes, at: area + 14)
            FixupApplier.prepareForWrite(data: &bytes, updateSequenceOffset: Int(NTFSVolumeWriter.u16(bytes, 4)),
                                         updateSequenceSize: Int(NTFSVolumeWriter.u16(bytes, 6)), bytesPerSector: 512)
            try device.write(offset: start + page, data: bytes)
        }
        let unclean = try NTFSVolume(blockDevice: device)
        guard case .unclean = try unclean.journalState() else { return XCTFail("Journal should be unclean") }
        XCTAssertNotNil(NTFSVolumeWriter.writeSafetyIssue(unclean))
        let before = try device.read(offset: 0, count: Int(device.size))
        XCTAssertThrowsError(try unclean.writeFile(fileName: "b.txt", data: Data("b".utf8)))
        let existing = try unclean.lookup(path: "/a.txt").record.recordNumber
        XCTAssertThrowsError(try unclean.writeData(recordNumber: existing, offset: 0, data: Data("z".utf8)))
        XCTAssertEqual(try device.read(offset: 0, count: Int(device.size)), before)
        XCTAssertEqual(try unclean.readFile(at: "/a.txt"), Data("a".utf8))
    }

    func testSequentialAppendsWriteOnlyNewBytesStayContiguousAndSyncTheIndex() throws {
        let base = MemoryBlockDevice(data: Data(repeating: 0xA5, count: 64 << 20))
        try NTFSFormatter.format(device: base, options: .init(volumeName: "STREAM"))
        let device = CountingDevice(base)
        let volume = try NTFSVolume(blockDevice: device)
        let number = try volume.writeFile(fileName: "stream.bin", data: Data())
        var expected = Data()
        device.written = 0
        for i in 0..<128 {
            let chunk = Data(repeating: UInt8(i), count: 64 * 1024)
            try volume.writeData(recordNumber: number, offset: UInt64(expected.count), data: chunk, updateDirectory: false)
            expected.append(chunk)
        }
        // Rewriting the whole stream per call would write about 64 times the payload.
        XCTAssertLessThan(device.written, expected.count + expected.count / 4)
        let reopened = try NTFSVolume(blockDevice: base)
        XCTAssertEqual(try reopened.readFile(at: "/stream.bin"), expected)
        let runs = try XCTUnwrap(reopened.readMFTRecord(number: number).defaultDataAttribute?.runs)
        XCTAssertLessThanOrEqual(runs.count, 3)
        XCTAssertNotEqual(try reopened.listDirectory(at: "/").first { $0.name == "stream.bin" }?.fileSize,
                          UInt64(expected.count))

        try volume.syncDirectoryEntry(recordNumber: number)
        let synced = try NTFSVolume(blockDevice: base)
        XCTAssertEqual(try synced.listDirectory(at: "/").first { $0.name == "stream.bin" }?.fileSize, UInt64(expected.count))
        let cluster = UInt64(synced.bootSector.clusterSizeBytes)
        let record = try synced.readMFTRecord(number: number)
        XCTAssertEqual(try synced.dataSize(record: record).allocated, (UInt64(expected.count) + cluster - 1) / cluster * cluster)
        XCTAssertEqual(try synced.readFile(at: "/stream.bin"), expected)
        let name = try FileNameAttribute(data: XCTUnwrap(record.attribute(ofType: .fileName)?.residentData))
        XCTAssertEqual(name.realSize, UInt64(expected.count))
    }

    func testGrowingTruncateWritesNoPayloadAndUninitializedBytesReadAsZeros() throws {
        let base = MemoryBlockDevice(data: Data(repeating: 0xA5, count: 64 << 20))
        try NTFSFormatter.format(device: base, options: .init(volumeName: "GROW"))
        let device = CountingDevice(base)
        let volume = try NTFSVolume(blockDevice: device)
        let head = Data(repeating: 7, count: 10_000)
        let number = try volume.writeFile(fileName: "grow.bin", data: head)
        device.written = 0
        try volume.truncate(recordNumber: number, size: 20 << 20)
        XCTAssertLessThan(device.written, 256 * 1024)
        var reopened = try NTFSVolume(blockDevice: base)
        var record = try reopened.readMFTRecord(number: number)
        XCTAssertEqual(try reopened.readData(record: record, offset: 0, length: head.count), head)
        // The newly allocated clusters still hold 0xA5 on disk.
        XCTAssertEqual(try reopened.readData(record: record, offset: (20 << 20) - 4096, length: 4096), Data(count: 4096))

        try volume.writeData(recordNumber: number, offset: 15 << 20, data: Data([1, 2, 3]))
        reopened = try NTFSVolume(blockDevice: base)
        record = try reopened.readMFTRecord(number: number)
        XCTAssertEqual(try reopened.readData(record: record, offset: 12 << 20, length: 4096), Data(count: 4096))
        XCTAssertEqual(try reopened.readData(record: record, offset: (15 << 20) - 1, length: 5), Data([0, 1, 2, 3, 0]))
        XCTAssertEqual(try reopened.dataSize(record: record).size, 20 << 20)
        XCTAssertEqual(try reopened.listDirectory(at: "/").first { $0.name == "grow.bin" }?.fileSize, 20 << 20)
    }

    func testStreamChangesOnIndependentlyFormattedVolumePassIndependentChecker() throws {
        let tools = "/Library/Filesystems/tuxera_ntfs.fs/Contents/Resources/Support/10.9"
        guard FileManager.default.isExecutableFile(atPath: tools + "/ntfsck") else {
            throw XCTSkip("Optional independent NTFS tools are not installed")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 64 << 20)
        try handle.close()
        func run(_ tool: String, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: tools + "/" + tool)
            process.arguments = arguments
            process.standardOutput = output; process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }
        XCTAssertEqual(try run("mkntfs", ["-F", "-Q", "-L", "STREAMS", url.path]).0, 0)

        let device = try FileBlockDevice(path: url.path, writable: true)
        let volume = try NTFSVolume(blockDevice: device)
        var generator = SystemRandomNumberGenerator()
        var expected: [String: Data] = [:]
        _ = try volume.createDirectory(name: "streams")
        for index in 0..<12 {
            let name = "file-\(index).bin"
            let number = try volume.writeFile(fileName: name, data: Data(), directoryPath: "/streams")
            var content = Data()
            for _ in 0..<Int.random(in: 3...12, using: &generator) {
                let chunk = Data((0..<Int.random(in: 1...300_000, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
                try volume.writeData(recordNumber: number, offset: UInt64(content.count), data: chunk, updateDirectory: false)
                content.append(chunk)
            }
            if index % 3 == 0, content.count > 10 {
                let at = content.count / 3
                let patch = Data(repeating: 0xEE, count: min(5000, content.count - at))
                try volume.writeData(recordNumber: number, offset: UInt64(at), data: patch, updateDirectory: false)
                content.replaceSubrange(at..<(at + patch.count), with: patch)
            }
            if index % 4 == 1 {
                let size = content.count / 2 + 4097
                try volume.truncate(recordNumber: number, size: UInt64(size), updateDirectory: false)
                content = content.count >= size ? content.prefix(size) : content + Data(count: size - content.count)
            }
            if index % 4 == 2 {
                try volume.truncate(recordNumber: number, size: UInt64(content.count + 3_000_000), updateDirectory: false)
                content.append(Data(count: 3_000_000))
            }
            try volume.syncDirectoryEntry(recordNumber: number)
            expected[name] = content
        }
        try device.flush()
        if let keep = ProcessInfo.processInfo.environment["MACNTFS_KEEP_STREAM_IMAGE"] {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: keep))
        }
        let check = try run("ntfsck", ["-s", "-P", url.path])
        XCTAssertEqual(check.0, 0, check.1)
        let listing = try run("ntfsls", ["-l", "-p", "/streams", url.path]).1
        let reopened = try NTFSVolume(blockDevice: device)
        for (name, content) in expected {
            XCTAssertEqual(try reopened.readFile(at: "/streams/" + name), content, name)
            XCTAssertTrue(listing.contains("\(content.count)"), "\(name) size \(content.count) missing in independent listing")
        }
    }

    func testRepairNeverOverwritesForeignBootSectorsAndKeepsMirrorInSync() throws {
        // A FAT/exFAT-style boot sector with a stale NTFS backup at the end must survive.
        var image = Data(count: 16 << 20)
        let ntfs = MemoryBlockDevice(data: Data(count: 16 << 20))
        try NTFSFormatter.format(device: ntfs, options: .init(volumeName: "OLD"))
        let backup = try ntfs.read(offset: ntfs.size - 512, count: 512)
        image.replaceSubrange((image.count - 512)..<image.count, with: backup)
        var foreign = Data(count: 512)
        foreign.replaceSubrange(3..<11, with: Data("EXFAT   ".utf8))
        foreign[510] = 0x55; foreign[511] = 0xAA
        image.replaceSubrange(0..<512, with: foreign)
        let device = MemoryBlockDevice(data: image)
        _ = try? NTFSVolumeChecker.repair(device: device)
        XCTAssertEqual(try device.read(offset: 0, count: 512), foreign)

        // A dirty flag is cleared in $MFT and $MFTMirr alike.
        let volume = try NTFSVolume(blockDevice: ntfs)
        let size = UInt64(volume.bootSector.mftRecordSizeBytes), cluster = UInt64(volume.bootSector.clusterSizeBytes)
        var record = try NTFSVolumeWriter.fixedRecord(NTFSVolumeWriter.readRuns(volume.mftRecordRuns, offset: 3 * size,
            count: Int(size), cluster: cluster, device: ntfs), boot: volume.bootSector)
        let attribute = try NTFSVolumeWriter.attributeOffset(type: 0x70, name: nil, record: record)
        NTFSVolumeWriter.put(UInt16(1), into: &record, at: attribute + Int(NTFSVolumeWriter.u16(record, attribute + 20)) + 10)
        let sealed = NTFSVolumeWriter.sealRecord(record, boot: volume.bootSector)
        let mirrorRuns = try XCTUnwrap(volume.readMFTRecord(number: 1).defaultDataAttribute?.runs)
        for runs in [volume.mftRecordRuns, mirrorRuns] {
            try NTFSVolumeWriter.mapRuns(runs, offset: 3 * size, count: sealed.count, cluster: cluster) { disk, _ in
                try ntfs.write(offset: disk, data: sealed)
            }
        }
        XCTAssertTrue(try NTFSVolume(blockDevice: ntfs).isDirty)
        try NTFSVolumeChecker.repair(device: ntfs)
        let repaired = try NTFSVolume(blockDevice: ntfs)
        XCTAssertFalse(repaired.isDirty)
        let primary = try NTFSVolumeWriter.readRuns(repaired.mftRecordRuns, offset: 3 * size, count: Int(size), cluster: cluster, device: ntfs)
        let mirror = try NTFSVolumeWriter.readRuns(mirrorRuns, offset: 3 * size, count: Int(size), cluster: cluster, device: ntfs)
        XCTAssertEqual(primary, mirror)
    }

    func testAppendOnNearlyFullVolumeFallsBackWithoutHeadroom() throws {
        let device = MemoryBlockDevice(data: Data(count: 32 << 20))
        try NTFSFormatter.format(device: device, options: .init(volumeName: "FULL"))
        let volume = try NTFSVolume(blockDevice: device)
        let cluster = Int(volume.bootSector.clusterSizeBytes)
        var content = Data(repeating: 1, count: 1 << 20)
        let number = try volume.writeFile(fileName: "a.bin", data: content)
        let bitmap = try volume.readData(record: volume.readMFTRecord(number: 6))
        let total = Int(volume.bootSector.totalSizeBytes) / cluster
        let free = (0..<total).filter { bitmap[$0 / 8] & (1 << ($0 % 8)) == 0 }.count
        try volume.writeFile(fileName: "filler.bin", data: Data(count: (free - 100) * cluster))
        let tail = Data(repeating: 2, count: 40 * cluster)
        try volume.writeData(recordNumber: number, offset: UInt64(content.count), data: tail)
        content.append(tail)
        XCTAssertEqual(try NTFSVolume(blockDevice: device).readFile(at: "/a.bin"), content)
        let tooMuch = Data(repeating: 3, count: 200 * cluster)
        let before = try device.read(offset: 0, count: Int(device.size))
        XCTAssertThrowsError(try volume.writeData(recordNumber: number, offset: UInt64(content.count), data: tooMuch))
        XCTAssertEqual(try device.read(offset: 0, count: Int(device.size)), before)
    }
}
