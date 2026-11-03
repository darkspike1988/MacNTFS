import Foundation
import NTFSCore

/// A device that shows a base image with a few bytes changed. The fuzzer changes the list of patches,
/// so a run does not copy the whole image.
final class PatchedDevice: BlockDevice, @unchecked Sendable {
    private let base: Data
    private let patches: [(offset: Int, value: UInt8)]

    var size: UInt64 { UInt64(base.count) }

    init(base: Data, patches: [(offset: Int, value: UInt8)]) {
        self.base = base
        self.patches = patches
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: count, totalSize: size)
        }
        let start = Int(offset)
        var data = base.subdata(in: start..<(start + count))
        for patch in patches where patch.offset >= start && patch.offset < start + count {
            data[patch.offset - start] = patch.value
        }
        return data
    }
}

/// Where damage is most likely to matter: the boot sector, the first MFT records and the index blocks.
struct FuzzRegion {
    let start: Int
    let length: Int
}

final class FuzzTarget {
    static let shared = FuzzTarget()

    private let base: Data
    private let regions: [FuzzRegion]

    private init() {
        let path = ProcessInfo.processInfo.environment["NTFS_FUZZ_BASE"] ?? "Tests/Fixtures/mini.img"
        guard let image = FileManager.default.contents(atPath: path) else {
            fatalError("Set NTFS_FUZZ_BASE to a NTFS image (default Tests/Fixtures/mini.img). Could not read \(path)")
        }
        base = image

        var regions = [FuzzRegion(start: 0, length: 512)]
        if let volume = try? NTFSVolume(blockDevice: MemoryBlockDevice(data: image)) {
            let recordSize = Int(volume.bootSector.mftRecordSizeBytes)
            let clusterSize = Int(volume.bootSector.clusterSizeBytes)
            // The first 64 MFT records, wherever the MFT runs put them.
            var mapped = 0
            for run in volume.mftRecordRuns {
                guard let lcn = run.startingLCN else { continue }
                let bytes = Int(run.clusterCount) * clusterSize
                regions.append(FuzzRegion(start: Int(lcn) * clusterSize, length: min(bytes, 64 * recordSize - mapped)))
                mapped += bytes
                if mapped >= 64 * recordSize { break }
            }
            // The index blocks of every directory in the first two levels.
            for item in (try? volume.listDirectory(at: "/")) ?? [] where item.isDirectory {
                if let record = try? volume.lookup(path: "/" + item.name).record,
                   let runs = record.attribute(ofType: .indexAllocation, name: "$I30")?.runs {
                    for run in runs {
                        if let lcn = run.startingLCN {
                            regions.append(FuzzRegion(start: Int(lcn) * clusterSize, length: Int(run.clusterCount) * clusterSize))
                        }
                    }
                }
            }
        }
        self.regions = regions.filter { $0.length > 0 && $0.start + $0.length <= image.count }
    }

    /// The input is a list of 4-byte patches: region, position (2 bytes), new value.
    func run(_ input: UnsafeBufferPointer<UInt8>) {
        var patches = [(offset: Int, value: UInt8)]()
        var index = 0
        while index + 4 <= input.count && patches.count < 128 {
            let region = regions[Int(input[index]) % regions.count]
            let position = (Int(input[index + 1]) | (Int(input[index + 2]) << 8)) % region.length
            patches.append((region.start + position, input[index + 3]))
            index += 4
        }

        let device = PatchedDevice(base: base, patches: patches)
        guard let volume = try? NTFSVolume(blockDevice: device) else { return }
        _ = volume.isDirty
        _ = try? volume.hibernationState()
        for number in 0..<32 {
            _ = try? volume.readMFTRecord(number: UInt64(number))
        }
        var budget = 200
        walk(volume, path: "/", depth: 0, budget: &budget)
    }

    private func walk(_ volume: NTFSVolume, path: String, depth: Int, budget: inout Int) {
        guard let items = try? volume.listDirectory(at: path) else { return }
        for item in items.prefix(40) {
            guard budget > 0 else { return }
            budget -= 1
            let child = path == "/" ? "/" + item.name : path + "/" + item.name
            if item.isDirectory {
                if depth < 3 { walk(volume, path: child, depth: depth + 1, budget: &budget) }
                continue
            }
            if let lookup = try? volume.lookup(path: child) {
                _ = try? volume.readData(record: lookup.record, offset: 0, length: 64 * 1024)
                for stream in lookup.record.dataStreams.prefix(4) {
                    _ = try? volume.readData(record: lookup.record, stream: stream.name, offset: 0, length: 4096)
                }
                _ = try? volume.readLink(at: child)
            }
        }
    }
}

/// Entry point for libFuzzer.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    FuzzTarget.shared.run(UnsafeBufferPointer(start: bytes, count: count))
    return 0
}
