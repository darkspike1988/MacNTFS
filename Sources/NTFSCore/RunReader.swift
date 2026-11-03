import Foundation

/// Reads bytes of a non-resident attribute through its data runs.
/// All arithmetic is checked, because run lists come from untrusted disks.
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
        guard length >= 0 else {
            throw NTFSError.outOfBounds(offset: virtualOffset, requested: length, available: 0)
        }
        if length == 0 { return Data() }
        guard clusterSize > 0 else {
            throw NTFSError.corruptRunlist("Cluster size is zero")
        }

        // Check the whole range against the mapped size before allocating anything.
        var mapped: UInt64 = 0
        for run in runs {
            let (bytes, overflow) = run.clusterCount.multipliedReportingOverflow(by: clusterSize)
            let (sum, sumOverflow) = mapped.addingReportingOverflow(bytes)
            guard !overflow, !sumOverflow else {
                throw NTFSError.corruptRunlist("Run list size overflows")
            }
            mapped = sum
        }
        let (requestedEnd, endOverflow) = virtualOffset.addingReportingOverflow(UInt64(length))
        guard !endOverflow, requestedEnd <= mapped else {
            throw NTFSError.outOfBounds(offset: virtualOffset, requested: length, available: Int(clamping: mapped))
        }

        var result = Data()
        result.reserveCapacity(length)
        var runStart: UInt64 = 0
        var position = virtualOffset
        var remaining = length

        for run in runs {
            let runBytes = run.clusterCount * clusterSize
            let runEnd = runStart + runBytes
            if position < runEnd {
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
                if remaining == 0 { return result }
            }
            runStart = runEnd
        }

        throw NTFSError.outOfBounds(offset: virtualOffset, requested: length, available: result.count)
    }
}
