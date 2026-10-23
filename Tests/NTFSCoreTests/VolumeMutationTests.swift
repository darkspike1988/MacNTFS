import Foundation
import XCTest
@testable import NTFSCore

final class VolumeMutationTests: XCTestCase {
    private func makeDevice() throws -> MemoryBlockDevice {
        let device = MemoryBlockDevice(data: Data(repeating: 0, count: 32 * 1024 * 1024))
        try NTFSFormatter.format(device: device, options: .init(volumeName: "MUTATIONS"))
        return device
    }

    private func snapshot(_ device: MemoryBlockDevice) throws -> Data {
        try device.read(offset: 0, count: Int(device.size))
    }

    private func bitmap(_ volume: NTFSVolume, record: UInt64 = 6) throws -> BitmapManager {
        let mft = try volume.readMFTRecord(number: record)
        if record == 0 {
            let attribute = try XCTUnwrap(mft.attribute(ofType: .bitmap))
            return BitmapManager(data: try NTFSVolumeWriter.streamData(attribute, volume: volume))
        }
        return BitmapManager(data: try volume.readData(record: mft))
    }

    private func clusters(_ record: MFTRecord) -> Set<UInt64> {
        Set((record.defaultDataAttribute?.runs ?? []).flatMap { run -> [UInt64] in
            guard let start = run.startingLCN else { return [] }
            return Array(start..<(start + run.clusterCount))
        })
    }

    private func assertUnchanged(_ device: MemoryBlockDevice, operation: () throws -> Void,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try snapshot(device)
        XCTAssertThrowsError(try operation(), file: file, line: line)
        XCTAssertTrue(try snapshot(device) == before, "Rejected mutation changed disk bytes", file: file, line: line)
    }

    func testNestedDirectoryCreationAndParentReferencesSurviveReopen() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let parent = try volume.createDirectory(name: "Parent")
        let child = try volume.createDirectory(name: "Child", directoryPath: "/Parent")
        let payload = Data("nested payload".utf8)
        let file = try volume.writeFile(fileName: "café.txt", data: payload, directoryPath: "/Parent/Child")
        let reopened = try NTFSVolume(blockDevice: device)
        XCTAssertEqual(try reopened.readFile(at: "/parent/child/CAFÉ.TXT"), payload)
        XCTAssertEqual(try reopened.listDirectory(at: "/Parent").map(\.name), ["Child"])
        XCTAssertEqual(try reopened.listDirectory(at: "/Parent/Child").map(\.name), ["café.txt"])
        for (number, expectedParent) in [(child, parent), (file, child)] {
            let record = try reopened.readMFTRecord(number: number)
            let name = try FileNameAttribute(data: XCTUnwrap(record.attribute(ofType: .fileName)?.residentData))
            XCTAssertEqual(name.parentDirectoryRecordNumber, expectedParent)
            XCTAssertEqual(name.parentDirectorySequenceNumber, try reopened.readMFTRecord(number: expectedParent).header.sequenceNumber)
        }
        try assertUnchanged(device) { _ = try volume.createDirectory(name: "PARENT") }
    }

    func testNonresidentOverwriteExtensionAndShrinkPreserveBytesAndReleaseClusters() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        var expected = Data((0..<16000).map { UInt8(($0 * 7) & 255) })
        let number = try volume.writeFile(fileName: "data.bin", data: expected)
        XCTAssertFalse(clusters(try volume.readMFTRecord(number: number)).isEmpty)
        let replacement = Data(repeating: 0xE7, count: 6000)
        try volume.writeData(recordNumber: number, offset: 3000, data: replacement)
        expected.replaceSubrange(3000..<9000, with: replacement)
        XCTAssertEqual(try NTFSVolume(blockDevice: device).readFile(at: "/data.bin"), expected)

        try volume.truncate(recordNumber: number, size: 23000)
        expected.append(Data(repeating: 0, count: 7000))
        XCTAssertEqual(try NTFSVolume(blockDevice: device).readFile(at: "/data.bin"), expected)
        let oldClusters = clusters(try NTFSVolume(blockDevice: device).readMFTRecord(number: number))
        try volume.truncate(recordNumber: number, size: 17)
        let reopened = try NTFSVolume(blockDevice: device)
        XCTAssertEqual(try reopened.readFile(at: "/data.bin"), Data(expected.prefix(17)))
        XCTAssertNotNil(try reopened.readMFTRecord(number: number).defaultDataAttribute?.residentData)
        let allocation = try bitmap(reopened)
        // Freed clusters may be reused at once, e.g. by the rebuilt parent index.
        let rootIndex = Set((try reopened.readMFTRecord(number: 5).attribute(ofType: .indexAllocation, name: "$I30")?.runs ?? [])
            .flatMap { run in run.startingLCN.map { Array($0..<($0 + run.clusterCount)) } ?? [] })
        for cluster in oldClusters where !rootIndex.contains(cluster) {
            XCTAssertFalse(allocation.isAllocated(at: Int(cluster)), "Shrink leaked cluster \(cluster)")
        }
        let index = try XCTUnwrap(reopened.listDirectory(at: "/").first { $0.name == "data.bin" })
        XCTAssertEqual(index.fileSize, 17)
    }

    func testWriteBeyondEndZeroFillsGapAndInvalidWriteLeavesImageUnchanged() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let number = try volume.writeFile(fileName: "gap.bin", data: Data([1, 2, 3]))
        try volume.writeData(recordNumber: number, offset: 10000, data: Data([4, 5]))
        var expected = Data([1, 2, 3])
        expected.append(Data(repeating: 0, count: 9997))
        expected.append(contentsOf: [4, 5])
        XCTAssertEqual(try NTFSVolume(blockDevice: device).readFile(at: "/gap.bin"), expected)
        let directory = try volume.createDirectory(name: "folder")
        try assertUnchanged(device) { try volume.writeData(recordNumber: directory, offset: 0, data: Data([9])) }
        try assertUnchanged(device) { try volume.truncate(recordNumber: number, size: UInt64.max) }
    }

    func testCrossDirectoryAndCaseOnlyRenamePreserveRecordAndPayload() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        _ = try volume.createDirectory(name: "from")
        let destination = try volume.createDirectory(name: "to")
        let payload = Data(repeating: 0x53, count: 11000)
        let number = try volume.writeFile(fileName: "name.bin", data: payload, directoryPath: "/from")
        try volume.renameItem(sourcePath: "/from/name.bin", destinationPath: "/to/moved.bin")
        try volume.renameItem(sourcePath: "/to/moved.bin", destinationPath: "/to/MOVED.BIN")
        let reopened = try NTFSVolume(blockDevice: device)
        XCTAssertTrue(try reopened.listDirectory(at: "/from").isEmpty)
        XCTAssertEqual(try reopened.listDirectory(at: "/to").map(\.name), ["MOVED.BIN"])
        XCTAssertEqual(try reopened.lookup(path: "/to/MOVED.BIN").record.recordNumber, number)
        XCTAssertEqual(try reopened.readFile(at: "/to/MOVED.BIN"), payload)
        let filename = try FileNameAttribute(data: XCTUnwrap(reopened.readMFTRecord(number: number).attribute(ofType: .fileName)?.residentData))
        XCTAssertEqual(filename.parentDirectoryRecordNumber, destination)
        XCTAssertEqual(filename.name, "MOVED.BIN")
    }

    func testRenameReplacementFreesReplacedRecordAndPayloadAllocation() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let payload = Data(repeating: 0x24, count: 14000)
        let source = try volume.writeFile(fileName: "source.bin", data: payload)
        let replaced = try volume.writeFile(fileName: "existing.bin", data: Data(repeating: 0xEE, count: 19000))
        let replacedClusters = clusters(try volume.readMFTRecord(number: replaced))
        XCTAssertFalse(replacedClusters.isEmpty)
        try assertUnchanged(device) { try volume.renameItem(sourcePath: "/source.bin", destinationPath: "/existing.bin") }
        try volume.renameItem(sourcePath: "/source.bin", destinationPath: "/existing.bin", replaceExisting: true)
        let reopened = try NTFSVolume(blockDevice: device)
        XCTAssertEqual(try reopened.readFile(at: "/existing.bin"), payload)
        XCTAssertEqual(try reopened.lookup(path: "/existing.bin").record.recordNumber, source)
        XCTAssertThrowsError(try reopened.lookup(path: "/source.bin"))
        XCTAssertFalse(try reopened.readMFTRecord(number: replaced).isInUse)
        XCTAssertFalse(try bitmap(reopened, record: 0).isAllocated(at: Int(replaced)))
        let allocation = try bitmap(reopened)
        for cluster in replacedClusters { XCTAssertFalse(allocation.isAllocated(at: Int(cluster))) }
    }

    func testDirectoryCycleAndNonemptyRemovalLeaveEveryByteUnchanged() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        _ = try volume.createDirectory(name: "parent")
        _ = try volume.createDirectory(name: "child", directoryPath: "/parent")
        _ = try volume.writeFile(fileName: "keep.txt", data: Data("keep".utf8), directoryPath: "/parent/child")
        try assertUnchanged(device) { try volume.renameItem(sourcePath: "/parent", destinationPath: "/parent/child/cycle") }
        try assertUnchanged(device) { try volume.removeItem(name: "parent") }
        try assertUnchanged(device) { try volume.removeItem(name: "child", directoryPath: "/parent") }
        XCTAssertEqual(try NTFSVolume(blockDevice: device).readFile(at: "/parent/child/keep.txt"), Data("keep".utf8))
    }

    func testDeletionReusesMFTSlotWithNewSequenceAndNoPayloadAllocationLeak() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let number = try volume.writeFile(fileName: "deleted.bin", data: Data(repeating: 0xDA, count: 18000))
        let oldRecord = try volume.readMFTRecord(number: number)
        let allocated = clusters(oldRecord)
        try volume.removeItem(name: "deleted.bin")
        let afterDeletion = try NTFSVolume(blockDevice: device)
        XCTAssertFalse(try afterDeletion.readMFTRecord(number: number).isInUse)
        XCTAssertFalse(try bitmap(afterDeletion, record: 0).isAllocated(at: Int(number)))
        let bits = try bitmap(afterDeletion)
        for cluster in allocated { XCTAssertFalse(bits.isAllocated(at: Int(cluster))) }
        let replacement = try volume.writeFile(fileName: "new.txt", data: Data("fresh".utf8))
        XCTAssertEqual(replacement, number)
        let reopened = try NTFSVolume(blockDevice: device)
        let newRecord = try reopened.readMFTRecord(number: replacement)
        XCTAssertNotEqual(newRecord.header.sequenceNumber, oldRecord.header.sequenceNumber)
        XCTAssertEqual(try reopened.readFile(at: "/new.txt"), Data("fresh".utf8))
        XCTAssertTrue(clusters(newRecord).isEmpty)
        XCTAssertThrowsError(try reopened.lookup(path: "/deleted.bin"))
        let root = try reopened.readMFTRecord(number: 5)
        let entry = try XCTUnwrap(NTFSVolumeWriter.readIndexEntries(volume: reopened, parent: root).first {
            (try? NTFSVolumeWriter.entryName($0)) == "new.txt"
        })
        let parsed = try IndexEntryParser.parse(data: entry, offset: 0)
        XCTAssertEqual(parsed.sequenceNumber, newRecord.header.sequenceNumber)
        XCTAssertEqual(parsed.mftRecordNumber, replacement)
    }

    func testSetTimesKeepsStandardInformationFilenameAndParentIndexInSync() throws {
        let device = try makeDevice()
        let volume = try NTFSVolume(blockDevice: device)
        let number = try volume.writeFile(fileName: "times.txt", data: Data("unchanged".utf8))
        let creation = Date(timeIntervalSince1970: 1_600_000_000)
        let modification = creation.addingTimeInterval(12345)
        let access = creation.addingTimeInterval(23456)
        try volume.setFileTimes(recordNumber: number, creation: creation, modification: modification, access: access)
        let reopened = try NTFSVolume(blockDevice: device)
        let record = try reopened.readMFTRecord(number: number)
        let si = try StandardInformation(data: XCTUnwrap(record.attribute(ofType: .standardInformation)?.residentData))
        let fn = try FileNameAttribute(data: XCTUnwrap(record.attribute(ofType: .fileName)?.residentData))
        let root = try reopened.readMFTRecord(number: 5)
        let entry = try XCTUnwrap(NTFSVolumeWriter.readIndexEntries(volume: reopened, parent: root).first {
            (try? NTFSVolumeWriter.entryName($0)) == "times.txt"
        })
        let indexName = try XCTUnwrap(IndexEntryParser.parse(data: entry, offset: 0).fileName)
        for name in [fn, indexName] {
            XCTAssertEqual(name.creationTime, creation)
            XCTAssertEqual(name.modificationTime, modification)
            XCTAssertEqual(name.accessTime, access)
            XCTAssertEqual(name.creationTime, si.creationTime)
            XCTAssertEqual(name.modificationTime, si.modificationTime)
            XCTAssertEqual(name.accessTime, si.accessTime)
        }
        XCTAssertEqual(try reopened.readFile(at: "/times.txt"), Data("unchanged".utf8))
    }

    func testMutationSequencePassesOptionalIndependentChecker() throws {
        guard let checker = ProcessInfo.processInfo.environment["MACNTFS_NTFSCK_PATH"],
              FileManager.default.isExecutableFile(atPath: checker) else {
            throw XCTSkip("Set MACNTFS_NTFSCK_PATH to an independent ntfsck executable")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("mutation-sequence.img")
        try Data(repeating: 0, count: 64 * 1024 * 1024).write(to: image)
        let device = try FileBlockDevice(path: image.path, writable: true)
        try NTFSFormatter.format(device: device)
        let volume = try NTFSVolume(blockDevice: device)
        _ = try volume.createDirectory(name: "alpha")
        _ = try volume.createDirectory(name: "beta")
        let number = try volume.writeFile(fileName: "data.bin", data: Data(repeating: 0x42, count: 18000), directoryPath: "/alpha")
        try volume.writeData(recordNumber: number, offset: 5000, data: Data(repeating: 0x63, count: 2000))
        try volume.truncate(recordNumber: number, size: 25000)
        try volume.renameItem(sourcePath: "/alpha/data.bin", destinationPath: "/beta/moved.bin")
        try volume.setFileTimes(recordNumber: number, modification: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try volume.writeFile(fileName: "temporary.bin", data: Data(repeating: 0x78, count: 9000), directoryPath: "/beta")
        try volume.removeItem(name: "temporary.bin", directoryPath: "/beta")
        try volume.removeItem(name: "alpha")
        try device.flush()
        let before = try Data(contentsOf: image)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: checker)
        process.arguments = ["-s", "-P", "-t", "15", image.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        XCTAssertTrue(try Data(contentsOf: image) == before, "Simulated checker changed image")
        var expected = Data(repeating: 0x42, count: 18000)
        expected.replaceSubrange(5000..<7000, with: Data(repeating: 0x63, count: 2000))
        expected.append(Data(repeating: 0, count: 7000))
        XCTAssertEqual(try NTFSVolume(blockDevice: device).readFile(at: "/beta/moved.bin"), expected)
    }

}
