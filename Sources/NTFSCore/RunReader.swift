import Foundation

/// The run list of a non-resident attribute with where each run starts, so a position can be found by
/// binary search. All arithmetic is checked, because run lists come from untrusted disks.
struct RunMap {
    let runs: [DataRun]
    /// First virtual cluster number (VCN) of each run.
    let starts: [UInt64]
    let totalClusters: UInt64

    init(runs: [DataRun]) throws {
        var starts = [UInt64]()
        starts.reserveCapacity(runs.count)
        var total: UInt64 = 0
        for run in runs {
            starts.append(total)
            let (sum, overflow) = total.addingReportingOverflow(run.clusterCount)
            guard !overflow else {
                throw NTFSError.corruptRunlist("Run list size overflows")
            }
            total = sum
        }
        self.runs = runs
        self.starts = starts
        self.totalClusters = total
    }

    /// Index of the run that contains the cluster `vcn`, or `runs.count` if no run does.
    func runIndex(containing vcn: UInt64) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= vcn { low = middle + 1 } else { high = middle }
        }
        let index = max(0, low - 1)
        return index < runs.count && vcn < starts[index] + runs[index].clusterCount ? index : runs.count
    }
}

/// Reads bytes of a non-resident attribute through its data runs.
enum RunReader {
    /// Reads exactly `length` bytes starting at logical byte `virtualOffset`.
    /// Sparse runs read as zeros. Throws if the range is not fully mapped by `runs`
    /// or if a run points outside the device.
    static func read(
        runs: [DataRun],
        virtualOffset: UInt64,
        length: Int,
        clusterSize: UInt64,
        device: BlockDevice
    ) throws -> Data {
        guard length > 0 else {
            return try read(map: RunMap(runs: []), virtualOffset: virtualOffset, length: length, clusterSize: clusterSize, device: device)
        }
        return try read(map: RunMap(runs: runs), virtualOffset: virtualOffset, length: length, clusterSize: clusterSize, device: device)
    }

    /// Same as `read(runs:...)` for a run list that is read many times: the map is built once.
    static func read(
        map: RunMap,
        virtualOffset: UInt64,
        length: Int,
        clusterSize: UInt64,
        device: BlockDevice
    ) throws -> Data {
        guard length >= 0 else {
            throw NTFSError.outOfBounds(offset: virtualOffset, requested: length, available: 0)
        }
        if length == 0 { return Data() }
        guard clusterSize > 0 else {
            throw NTFSError.corruptRunlist("Cluster size is zero")
        }

        // Check the whole range against the mapped size before allocating anything.
        let (mapped, mappedOverflow) = map.totalClusters.multipliedReportingOverflow(by: clusterSize)
        guard !mappedOverflow else {
            throw NTFSError.corruptRunlist("Run list size overflows")
        }
        let (requestedEnd, endOverflow) = virtualOffset.addingReportingOverflow(UInt64(length))
        guard !endOverflow, requestedEnd <= mapped else {
            throw NTFSError.outOfBounds(offset: virtualOffset, requested: length, available: Int(clamping: mapped))
        }

        var result = Data()
        result.reserveCapacity(length)
        var position = virtualOffset
        var remaining = length
        var index = map.runIndex(containing: virtualOffset / clusterSize)

        while remaining > 0, index < map.runs.count {
            let run = map.runs[index]
            // These products are bounded by `mapped`, which was checked above.
            let runStart = map.starts[index] * clusterSize
            let runBytes = run.clusterCount * clusterSize
            let within = position - runStart
            let chunk = Int(min(UInt64(remaining), runBytes - within))

            if let lcn = run.startingLCN {
                let (base, o1) = lcn.multipliedReportingOverflow(by: clusterSize)
                let (diskOffset, o2) = base.addingReportingOverflow(within)
                let (diskEnd, o3) = diskOffset.addingReportingOverflow(UInt64(chunk))
                guard !o1, !o2, !o3, diskEnd <= device.size else {
                    throw NTFSError.outOfBounds(offset: diskOffset, requested: chunk, available: 0)
                }
                result.append(try device.read(offset: diskOffset, count: chunk))
            } else {
                result.append(Data(count: chunk))
            }

            remaining -= chunk
            position += UInt64(chunk)
            index += 1
        }

        guard remaining == 0 else {
            throw NTFSError.outOfBounds(offset: virtualOffset, requested: length, available: result.count)
        }
        return result
    }
}
