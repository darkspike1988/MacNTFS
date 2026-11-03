import XCTest
@testable import NTFSCore

/// The three ways a compression unit is stored, built by hand. Clusters have 512 bytes and a unit has 16 clusters.
final class CompressedReaderTests: XCTestCase {
    private let clusterSize: UInt64 = 512
    private let unitBytes = 16 * 512

    /// A device whose first cluster holds an LZNT1 chunk with the 8 literals "abcdefgh".
    private func deviceWithCompressedFirstCluster(clusters: Int = 32) -> MemoryBlockDevice {
        var data = Data(count: clusters * 512)
        let chunk: [UInt8] = [0x08, 0xB0, 0x00] + Array("abcdefgh".utf8)
        data.replaceSubrange(0..<chunk.count, with: chunk)
        return MemoryBlockDevice(data: data)
    }

    private func read(_ runs: [DataRun], offset: UInt64, length: Int, unitShift: Int = 4, device: BlockDevice) throws -> Data {
        try CompressedRunReader.read(runs: runs, unitShift: unitShift, offset: offset, length: length, clusterSize: clusterSize, device: device)
    }

    func testCompressedUnitExpandsAndIsPaddedWithZeros() throws {
        let runs = [DataRun(clusterCount: 1, startingLCN: 0), DataRun(clusterCount: 15, startingLCN: nil)]
        let data = try read(runs, offset: 0, length: unitBytes, device: deviceWithCompressedFirstCluster())
        XCTAssertEqual(data.count, unitBytes)
        XCTAssertEqual(data.prefix(8), Data("abcdefgh".utf8))
        XCTAssertEqual(data.dropFirst(8), Data(count: unitBytes - 8))
    }

    func testStoredUnitIsCopiedAsItIs() throws {
        let pattern = Data((0..<(unitBytes)).map { UInt8($0 & 0xFF) })
        let device = MemoryBlockDevice(data: pattern)
        let data = try read([DataRun(clusterCount: 16, startingLCN: 0)], offset: 100, length: 500, device: device)
        XCTAssertEqual(data, pattern.subdata(in: 100..<600))
    }

    func testUnitOfHolesIsZeros() throws {
        let data = try read([DataRun(clusterCount: 16, startingLCN: nil)], offset: 0, length: unitBytes, device: MemoryBlockDevice(data: Data(count: 512)))
        XCTAssertEqual(data, Data(count: unitBytes))
    }

    func testLastUnitMayEndBeyondTheRunsWhenOnlyTheStartIsRequested() throws {
        // 1 allocated and 3 sparse clusters are mapped. The rest of the unit counts as holes, because it is not requested.
        let runs = [DataRun(clusterCount: 1, startingLCN: 0), DataRun(clusterCount: 3, startingLCN: nil)]
        let data = try read(runs, offset: 0, length: 100, device: deviceWithCompressedFirstCluster())
        XCTAssertEqual(data.prefix(8), Data("abcdefgh".utf8))
        XCTAssertEqual(data.count, 100)
    }

    func testContentBeyondTheRunsIsAnErrorAndNotZeros() {
        let device = deviceWithCompressedFirstCluster()
        XCTAssertThrowsError(try read([DataRun(clusterCount: 16, startingLCN: 0)], offset: 8000, length: 1000, device: device)) { error in
            guard case NTFSError.outOfBounds = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertThrowsError(try read([], offset: 0, length: 10, device: device), "no runs at all")
    }

    func testAllocatedClustersAfterAHoleAreRejected() {
        let runs = [DataRun(clusterCount: 4, startingLCN: nil), DataRun(clusterCount: 12, startingLCN: 0)]
        XCTAssertThrowsError(try read(runs, offset: 0, length: unitBytes, device: deviceWithCompressedFirstCluster())) { error in
            guard case NTFSError.corruptRunlist = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testHugeOffsetsDoNotTrap() {
        let device = deviceWithCompressedFirstCluster()
        XCTAssertThrowsError(try read([], offset: UInt64.max - 100, length: 1, device: device))
        XCTAssertThrowsError(try read([DataRun(clusterCount: 16, startingLCN: 0)], offset: UInt64.max - 70_000, length: 65_536, device: device))
    }

    func testInvalidUnitSizesAreRejected() {
        let device = deviceWithCompressedFirstCluster()
        let runs = [DataRun(clusterCount: 16, startingLCN: 0)]
        XCTAssertThrowsError(try read(runs, offset: 0, length: 10, unitShift: 0, device: device))
        XCTAssertThrowsError(try read(runs, offset: 0, length: 10, unitShift: 9, device: device))
    }

    func testChunkShorterThan4096IsPaddedBeforeTheNextChunk() throws {
        // Two compressed chunks of 8 literals each. The first must be padded to 4096 bytes.
        let first: [UInt8] = [0x08, 0xB0, 0x00] + Array("abcdefgh".utf8)
        let second: [UInt8] = [0x08, 0xB0, 0x00] + Array("ijklmnop".utf8)
        let output = try LZNT1.decompress(Data(first + second), maxOutput: 8192)
        XCTAssertEqual(output.count, 4096 + 8)
        XCTAssertEqual(output.prefix(8), Data("abcdefgh".utf8))
        XCTAssertEqual(output.subdata(in: 8..<4096), Data(count: 4088))
        XCTAssertEqual(output.suffix(8), Data("ijklmnop".utf8))
    }
}
