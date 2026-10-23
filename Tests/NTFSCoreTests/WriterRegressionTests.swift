import Foundation
import XCTest
@testable import NTFSCore

final class WriterRegressionTests: XCTestCase {
    private func makeDevice() throws -> MemoryBlockDevice {
        let device = MemoryBlockDevice(data: Data(repeating: 0, count: 30 * 1024 * 1024))
        try NTFSFormatter.format(device: device, options: .init(volumeName: "WRITER_REGRESSION"))
        return device
    }

    private func snapshot(_ device: MemoryBlockDevice) throws -> Data {
        try device.read(offset: 0, count: Int(device.size))
    }

    private final class FailingDevice: BlockDevice, @unchecked Sendable {
        let backing: MemoryBlockDevice
        var writesUntilFailure: Int?
        var failNextFlush = false
        var injectedFailure = false
        var size: UInt64 { backing.size }
        var isWritable: Bool { backing.isWritable }
        init(backing: MemoryBlockDevice) { self.backing = backing }
        func read(offset: UInt64, count: Int) throws -> Data {
            try backing.read(offset: offset, count: count)
        }
        func write(offset: UInt64, data: Data) throws {
            if let remaining = writesUntilFailure {
                if remaining == 1 {
                    writesUntilFailure = nil
                    injectedFailure = true
                    // Simulate a device that modifies bytes before reporting EIO.
                    try backing.write(offset: offset, data: Data(data.prefix(max(1, data.count / 2))))
                    throw BlockDeviceError.writeFailed(errno: 5, message: "Injected partial write")
                }
                writesUntilFailure = remaining - 1
            }
            try backing.write(offset: offset, data: data)
        }
        func flush() throws {
            if failNextFlush {
                failNextFlush = false
                injectedFailure = true
                throw BlockDeviceError.writeFailed(errno: 5, message: "Injected flush failure")
            }
            try backing.flush()
        }
    }

    func testManyFilesSpillDirectoryIndexAndSurviveReopening() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        var expected: [String: Data] = [:]
        // More entries than either a resident root or a single index block can hold.
        for index in 0..<55 {
            let name = String(format: "file-%03d.bin", index)
            let size = index.isMultiple(of: 3) ? 9000 + index : 80 + index
            let payload = Data((0..<size).map { UInt8(($0 + index) & 0xff) })
            try volume.writeFile(fileName: name, data: payload)
            expected[name] = payload
        }

        let reopened = try NTFSVolume(blockDevice: device)
        let entries = try reopened.listDirectory(at: "/")
        XCTAssertEqual(entries.count, expected.count)
        XCTAssertEqual(Set(entries.map(\.name)), Set(expected.keys))
        let root = try reopened.readMFTRecord(number: 5)
        XCTAssertNotNil(root.attribute(ofType: .indexAllocation, name: "$I30"))
        XCTAssertNotNil(root.attribute(ofType: .bitmap, name: "$I30"))
        for (name, payload) in expected {
            XCTAssertEqual(try reopened.readFile(at: "/" + name), payload, name)
        }
    }

    func testCaseInsensitiveDuplicateLeavesImageUnchanged() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let original = Data("original payload".utf8)
        try volume.writeFile(fileName: "Report.txt", data: original)
        let before = try snapshot(device)

        XCTAssertThrowsError(try volume.writeFile(fileName: "REPORT.TXT", data: Data(repeating: 0x41, count: 12000)))
        XCTAssertTrue(try snapshot(device) == before, "Rejecting a duplicate must not change any disk bytes")
        let reopened = try NTFSVolume(blockDevice: device)
        XCTAssertEqual(try reopened.listDirectory(at: "/").count, 1)
        XCTAssertEqual(try reopened.readFile(at: "/Report.txt"), original)
    }

    func testCreatedRecordsAreMarkedInMFTBitmap() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        var records: [UInt64] = []
        for index in 0..<4 {
            records.append(try volume.writeFile(fileName: "bitmap-\(index).txt", data: Data([UInt8(index)])))
        }
        let reopened = try NTFSVolume(blockDevice: device)
        let mft = try reopened.readMFTRecord(number: 0)
        let bitmapAttribute = try XCTUnwrap(mft.attribute(ofType: .bitmap))
        let bitmapData = try XCTUnwrap(bitmapAttribute.residentData)
        let bitmap = BitmapManager(data: bitmapData)
        for record in records {
            XCTAssertTrue(bitmap.isAllocated(at: Int(record)), "MFT record \(record) is in use and must have an allocated bitmap bit")
            XCTAssertTrue(try reopened.readMFTRecord(number: record).isInUse)
        }
    }

    func testOversizedUTF16NamesRejectBeforeChangingDisk() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let before = try snapshot(device)
        // 128 user-perceived characters encode to 256 UTF-16 code units.
        for name in [String(repeating: "a", count: 256), String(repeating: "😀", count: 128)] {
            XCTAssertThrowsError(try volume.writeFile(fileName: name, data: Data(repeating: 0x42, count: 12000)))
            XCTAssertTrue(try snapshot(device) == before, "Invalid UTF-16 length must be rejected before any writes")
        }
    }

    func testFileRecordWritesFollowFragmentedMFTRuns() throws {
        let device = try makeDevice()
        let original = try NTFSVolume(blockDevice: device)
        let boot = original.bootSector
        let clusterSize = UInt64(boot.clusterSizeBytes)
        let first = try XCTUnwrap(original.mftRecordRuns.first)
        let originalLCN = try XCTUnwrap(first.startingLCN)
        let firstExtentClusters: UInt64 = 4
        let movedLCN: UInt64 = 512
        XCTAssertGreaterThan(first.clusterCount, firstExtentClusters)
        let movedClusters = first.clusterCount - firstExtentClusters
        let oldTailOffset = (originalLCN + firstExtentClusters) * clusterSize
        let tailLength = Int(movedClusters * clusterSize)
        let oldTail = try device.read(offset: oldTailOffset, count: tailLength)
        try device.write(offset: movedLCN * clusterSize, data: oldTail)

        // Preserve every attribute and change only the existing $MFT $DATA runlist.
        var raw = try device.read(offset: boot.mftByteOffset, count: Int(boot.mftRecordSizeBytes))
        func read16(_ offset: Int) throws -> UInt16 {
            var reader = BinaryReader(data: raw, offset: offset)
            return try reader.readUInt16()
        }
        func read32(_ offset: Int) throws -> UInt32 {
            var reader = BinaryReader(data: raw, offset: offset)
            return try reader.readUInt32()
        }
        let usaOffset = Int(try read16(4))
        let usaCount = Int(try read16(6))
        try FixupApplier.applyFixup(data: &raw, updateSequenceOffset: usaOffset, updateSequenceSize: usaCount, bytesPerSector: Int(boot.bytesPerSector))
        var attributeOffset = Int(try read16(0x14))
        var foundData = false
        while attributeOffset + 16 <= raw.count {
            let type = try read32(attributeOffset)
            if type == 0xffffffff { break }
            let length = Int(try read32(attributeOffset + 4))
            guard length >= 16 else { return XCTFail("Invalid fixture attribute length") }
            if type == 0x80 {
                let runOffset = Int(try read16(attributeOffset + 32))
                let runs = DataRunEncoder.encode(runs: [
                    DataRun(clusterCount: firstExtentClusters, startingLCN: originalLCN),
                    DataRun(clusterCount: movedClusters, startingLCN: movedLCN)
                ])
                guard runs.count <= length - runOffset else { return XCTFail("Fixture runlist no longer fits attribute padding") }
                raw.replaceSubrange((attributeOffset + runOffset)..<(attributeOffset + runOffset + runs.count), with: runs)
                foundData = true
                break
            }
            attributeOffset += length
        }
        XCTAssertTrue(foundData)
        FixupApplier.prepareForWrite(data: &raw, updateSequenceOffset: usaOffset, updateSequenceSize: usaCount, bytesPerSector: Int(boot.bytesPerSector))
        try device.write(offset: boot.mftByteOffset, data: raw)

        let bitmapRecord = try original.readMFTRecord(number: 6)
        var bitmap = BitmapManager(data: try original.readData(record: bitmapRecord))
        for cluster in movedLCN..<(movedLCN + movedClusters) {
            try bitmap.setAllocated(at: Int(cluster), isAllocated: true)
        }
        let bitmapLCN = try XCTUnwrap(bitmapRecord.defaultDataAttribute?.runs?.first?.startingLCN)
        try device.write(offset: bitmapLCN * clusterSize, data: bitmap.data)

        let fragmented = try NTFSVolume(blockDevice: device)
        XCTAssertEqual(fragmented.mftRecordRuns.count, 2)
        let payload = Data("record in second extent".utf8)
        let created = try fragmented.writeFile(fileName: "fragmented.txt", data: payload)
        XCTAssertGreaterThanOrEqual(created, 16)
        let reopened = try NTFSVolume(blockDevice: device)
        XCTAssertTrue(try reopened.readMFTRecord(number: created).isInUse)
        XCTAssertEqual(try reopened.readFile(at: "/fragmented.txt"), payload)
        XCTAssertTrue(try device.read(offset: oldTailOffset, count: tailLength) == oldTail, "The abandoned physical tail is outside the MFT runlist")
    }

    func testPartialWriteAndFlushFailuresRestoreEntireImageAndPermitRetry() throws {
        // Exercise payload, record, allocation metadata, parent updates, and final flush.
        for failurePoint in 1...6 {
            let backing = try makeDevice()
            let device = FailingDevice(backing: backing)
            let volume = try NTFSVolume(blockDevice: device)
            let before = try snapshot(backing)
            let payload = Data((0..<12000).map { UInt8($0 & 0xff) })
            if failurePoint == 6 { device.failNextFlush = true }
            else { device.writesUntilFailure = failurePoint }

            XCTAssertThrowsError(try volume.writeFile(fileName: "retry.bin", data: payload))
            XCTAssertTrue(device.injectedFailure, "Fault point \(failurePoint) was not reached")
            XCTAssertTrue(try snapshot(backing) == before, "Fault point \(failurePoint) left modified disk bytes")
            XCTAssertEqual(try NTFSVolume(blockDevice: backing).listDirectory(at: "/").count, 0)

            try volume.writeFile(fileName: "retry.bin", data: payload)
            let reopened = try NTFSVolume(blockDevice: backing)
            XCTAssertEqual(try reopened.readFile(at: "/retry.bin"), payload)
            XCTAssertEqual(try reopened.listDirectory(at: "/").count, 1)
        }
    }

    func testNonresidentPayloadAllocatesAcrossFragmentedFreeClusters() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let bitmapRecord = try volume.readMFTRecord(number: 6)
        var bitmap = BitmapManager(data: try volume.readData(record: bitmapRecord))
        let totalClusters = Int(device.size / UInt64(volume.bootSector.clusterSizeBytes))
        for cluster in 0..<totalClusters where cluster.isMultiple(of: 2) {
            try bitmap.setAllocated(at: cluster, isAllocated: true)
        }
        let bitmapLCN = try XCTUnwrap(bitmapRecord.defaultDataAttribute?.runs?.first?.startingLCN)
        try device.write(offset: bitmapLCN * UInt64(volume.bootSector.clusterSizeBytes), data: bitmap.data)

        let payload = Data((0..<12000).map { UInt8(($0 * 7) & 0xff) })
        let recordNumber = try volume.writeFile(fileName: "fragmented-data.bin", data: payload)
        let reopened = try NTFSVolume(blockDevice: device)
        let record = try reopened.readMFTRecord(number: recordNumber)
        let runs = try XCTUnwrap(record.defaultDataAttribute?.runs)
        XCTAssertGreaterThan(runs.count, 1)
        XCTAssertEqual(try reopened.readFile(at: "/fragmented-data.bin"), payload)
        let afterBitmap = BitmapManager(data: try reopened.readData(record: reopened.readMFTRecord(number: 6)))
        for run in runs {
            let lcn = try XCTUnwrap(run.startingLCN)
            for cluster in lcn..<(lcn + run.clusterCount) {
                XCTAssertFalse(bitmap.isAllocated(at: Int(cluster)), "Writer reused an already allocated cluster")
                XCTAssertTrue(afterBitmap.isAllocated(at: Int(cluster)))
            }
        }
    }

    func testBeyondInitialMFTCapacityGrowsAndPreservesEntries() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let initialBytes = volume.mftRecordRuns.reduce(UInt64(0)) { $0 + $1.clusterCount }
            * UInt64(volume.bootSector.clusterSizeBytes)
        let initialCapacity = initialBytes / UInt64(volume.bootSector.mftRecordSizeBytes)
        let count = max(130, Int(initialCapacity) + 20)
        var expected: [String: Data] = [:]
        var createdRecords: [UInt64] = []
        for index in 0..<count {
            let name = String(format: "growth-%03d.txt", index)
            let payload = Data("payload \(index)".utf8)
            createdRecords.append(try volume.writeFile(fileName: name, data: payload))
            expected[name] = payload
        }
        let lastName = String(format: "growth-%03d.txt", count - 1)
        XCTAssertEqual(try volume.readFile(at: "/" + lastName), expected[lastName],
                       "The original volume must resolve records added after its MFT runlist snapshot")
        XCTAssertTrue(try volume.readMFTRecord(number: XCTUnwrap(createdRecords.last)).isInUse)
        let reopened = try NTFSVolume(blockDevice: device)
        let mft = try reopened.readMFTRecord(number: 0)
        let grownData = try XCTUnwrap(mft.defaultDataAttribute)
        XCTAssertGreaterThan(grownData.realDataSize, initialBytes)
        let bitmapAttribute = try XCTUnwrap(mft.attribute(ofType: .bitmap))
        let bitmapBytes: Data
        if let resident = bitmapAttribute.residentData {
            bitmapBytes = resident
        } else {
            var bytes = Data()
            for run in try XCTUnwrap(bitmapAttribute.runs) {
                let lcn = try XCTUnwrap(run.startingLCN)
                bytes.append(try device.read(offset: lcn * UInt64(reopened.bootSector.clusterSizeBytes),
                    count: Int(run.clusterCount) * Int(reopened.bootSector.clusterSizeBytes)))
            }
            bitmapBytes = Data(bytes.prefix(Int(bitmapAttribute.realDataSize)))
        }
        let allocated = BitmapManager(data: bitmapBytes)
        for record in createdRecords {
            XCTAssertTrue(allocated.isAllocated(at: Int(record)), "Missing MFT allocation bit for \(record)")
            XCTAssertTrue(try reopened.readMFTRecord(number: record).isInUse)
        }
        XCTAssertEqual(Set(try reopened.listDirectory(at: "/").map(\.name)), Set(expected.keys))
        for (name, payload) in expected {
            XCTAssertEqual(try reopened.readFile(at: "/" + name), payload)
        }
    }

    func testDirectorySpillRoundTripsWithSmallAndLargeClusters() throws {
        for clusterSize: UInt32 in [1024, 8192] {
            let device = MemoryBlockDevice(data: Data(repeating: 0, count: 30 * 1024 * 1024))
            try NTFSFormatter.format(device: device, options: .init(volumeName: "GEOMETRY", clusterSize: clusterSize))
            let volume = try NTFSVolume(blockDevice: device)
            // Long names force multiple index blocks at both cluster geometries.
            let count = 55
            var expected: [String: Data] = [:]
            for index in 0..<count {
                let name = String(format: "%03d-", index) + String(repeating: "n", count: 220) + ".bin"
                let payload = Data(repeating: UInt8(index), count: 3000 + index)
                try volume.writeFile(fileName: name, data: payload)
                expected[name] = payload
            }
            let reopened = try NTFSVolume(blockDevice: device)
            let root = try reopened.readMFTRecord(number: 5)
            XCTAssertNotNil(root.attribute(ofType: .indexAllocation, name: "$I30"))
            XCTAssertEqual(Set(try reopened.listDirectory(at: "/").map(\.name)), Set(expected.keys))
            for (name, payload) in expected {
                XCTAssertEqual(try reopened.readFile(at: "/" + name), payload, "Cluster size \(clusterSize)")
            }
        }
    }

    func testNonresidentWriteToRegularFileDoesNotLeakAllocation() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let existingPayload = Data("not a directory".utf8)
        let regularFile = try volume.writeFile(fileName: "parent.txt", data: existingPayload)
        let before = try snapshot(device)
        let bitmapBefore = try volume.readData(record: volume.readMFTRecord(number: 6))

        XCTAssertThrowsError(try NTFSVolumeWriter.writeFile(
            volume: volume,
            directoryRecordNumber: regularFile,
            fileName: "child.bin",
            data: Data(repeating: 0x61, count: 12000)
        ))

        let reopened = try NTFSVolume(blockDevice: device)
        let bitmapAfter = try reopened.readData(record: reopened.readMFTRecord(number: 6))
        XCTAssertEqual(bitmapAfter, bitmapBefore, "A failed create must not leak payload clusters")
        XCTAssertTrue(try snapshot(device) == before, "An invalid parent must be detected before disk changes")
        XCTAssertEqual(try reopened.readFile(at: "/parent.txt"), existingPayload)
    }
}
