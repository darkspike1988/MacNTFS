import Foundation

/// Reads the content of a compressed non-resident attribute.
///
/// NTFS cuts such an attribute into compression units of 2^n clusters (usually 16). Each unit is stored
/// in one of three ways, which the run list shows:
/// - all clusters are holes: the unit is zeros,
/// - all clusters are allocated: the unit is stored as it is,
/// - the first clusters are allocated and the rest are holes: the allocated part is LZNT1 data that expands
///   to the whole unit.
enum CompressedRunReader {
    /// Largest unit accepted. Real units are 16 clusters of at most 4 KiB.
    private static let maxUnitBytes: UInt64 = 1 << 20

    /// Reads `length` bytes of the uncompressed content starting at `offset`.
    static func read(
        runs: [DataRun],
        unitShift: Int,
        offset: UInt64,
        length: Int,
        clusterSize: UInt64,
        device: BlockDevice
    ) throws -> Data {
        guard length > 0 else { return Data() }
        guard unitShift >= 1, unitShift <= 8 else {
            throw NTFSError.corruptRunlist("A compressed attribute has the compression unit size 2^\(unitShift)")
        }
        let unitClusters = UInt64(1) << UInt64(unitShift)
        let (unitBytes, overflow) = unitClusters.multipliedReportingOverflow(by: clusterSize)
        guard !overflow, unitBytes > 0, unitBytes <= maxUnitBytes else {
            throw NTFSError.corruptRunlist("Compression units of \(unitClusters) clusters of \(clusterSize) bytes")
        }

        // Where each run starts, in clusters, for a search by VCN.
        var starts = [UInt64]()
        starts.reserveCapacity(runs.count)
        var totalClusters: UInt64 = 0
        for run in runs {
            starts.append(totalClusters)
            let (sum, sumOverflow) = totalClusters.addingReportingOverflow(run.clusterCount)
            guard !sumOverflow else { throw NTFSError.corruptRunlist("Run list size overflows") }
            totalClusters = sum
        }

        let (end, endOverflow) = offset.addingReportingOverflow(UInt64(length))
        guard !endOverflow else {
            throw NTFSError.outOfBounds(offset: offset, requested: length, available: 0)
        }

        var result = Data()
        result.reserveCapacity(length)
        var unit = offset / unitBytes
        let lastUnit = (end - 1) / unitBytes
        while unit <= lastUnit {
            let unitStart = unit * unitBytes
            let content = try decodeUnit(
                unit: unit,
                unitClusters: unitClusters,
                unitBytes: unitBytes,
                runs: runs,
                starts: starts,
                clusterSize: clusterSize,
                device: device
            )
            let from = Int(max(offset, unitStart) - unitStart)
            let to = Int(min(end, unitStart + unitBytes) - unitStart)
            result.append(content.subdata(in: from..<to))
            unit += 1
        }
        return result
    }

    private static func decodeUnit(
        unit: UInt64,
        unitClusters: UInt64,
        unitBytes: UInt64,
        runs: [DataRun],
        starts: [UInt64],
        clusterSize: UInt64,
        device: BlockDevice
    ) throws -> Data {
        let unitVCN = unit * unitClusters
        let unitEnd = unitVCN + unitClusters

        // Count the allocated clusters of this unit. They must come first, followed by holes.
        var allocated: UInt64 = 0
        var sawHole = false
        var vcn = unitVCN
        var index = firstRun(containing: unitVCN, starts: starts)
        while vcn < unitEnd, index < runs.count {
            let run = runs[index]
            let runEnd = starts[index] + run.clusterCount
            if vcn >= runEnd {
                index += 1
                continue
            }
            let taken = min(runEnd, unitEnd) - vcn
            if run.isSparse {
                sawHole = true
            } else {
                guard !sawHole else {
                    throw NTFSError.corruptRunlist("A compression unit has allocated clusters after a hole")
                }
                allocated += taken
            }
            vcn += taken
        }
        // Clusters after the last run count as holes.

        let unitStartByte = unit * unitBytes
        if allocated == 0 {
            return Data(count: Int(unitBytes))
        }
        if allocated == unitClusters {
            return try RunReader.read(runs: runs, virtualOffset: unitStartByte, length: Int(unitBytes), clusterSize: clusterSize, device: device)
        }

        let stored = try RunReader.read(
            runs: runs,
            virtualOffset: unitStartByte,
            length: Int(allocated * clusterSize),
            clusterSize: clusterSize,
            device: device
        )
        var content = try LZNT1.decompress(stored, maxOutput: Int(unitBytes))
        if content.count < Int(unitBytes) {
            content.append(Data(count: Int(unitBytes) - content.count))
        }
        return content
    }

    /// Index of the run that contains the cluster `vcn`, or `starts.count` if no run does.
    private static func firstRun(containing vcn: UInt64, starts: [UInt64]) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= vcn { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1) < starts.count ? max(0, low - 1) : starts.count
    }
}
