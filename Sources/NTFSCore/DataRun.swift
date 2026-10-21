import Foundation

/// A decoded data run representing a contiguous sequence of clusters on disk.
public struct DataRun: Equatable, Sendable {
    /// Number of clusters in this run.
    public let clusterCount: UInt64
    /// Starting Logical Cluster Number (LCN) on the volume, or nil if this is a sparse run.
    public let startingLCN: UInt64?

    public var isSparse: Bool {
        startingLCN == nil
    }

    public init(clusterCount: UInt64, startingLCN: UInt64?) {
        self.clusterCount = clusterCount
        self.startingLCN = startingLCN
    }
}

public enum RunlistDecoder {
    /// Decodes an NTFS compressed runlist byte buffer into an array of DataRun items.
    ///
    /// - Parameter data: Raw runlist bytes from a non-resident attribute header.
    /// - Returns: Array of `DataRun` items.
    public static func decode(data: Data) throws -> [DataRun] {
        var runs = [DataRun]()
        var reader = BinaryReader(data: data)
        var currentLCN: Int64 = 0

        while !reader.isEOF {
            let header = try reader.readUInt8()
            if header == 0x00 {
                // End of runlist
                break
            }

            let lengthSize = Int(header & 0x0F)
            let offsetSize = Int((header >> 4) & 0x0F)

            guard lengthSize > 0 && lengthSize <= 8 else {
                throw NTFSError.corruptRunlist("Invalid length size in run header: \(lengthSize)")
            }
            guard offsetSize <= 8 else {
                throw NTFSError.corruptRunlist("Invalid offset size in run header: \(offsetSize)")
            }

            // Read cluster count (unsigned)
            var count: UInt64 = 0
            for i in 0..<lengthSize {
                let byte = try reader.readUInt8()
                count |= (UInt64(byte) << (i * 8))
            }

            if offsetSize == 0 {
                // Sparse run
                runs.append(DataRun(clusterCount: count, startingLCN: nil))
            } else {
                // Read signed LCN delta with proper two's-complement sign extension
                let rawDeltaBytes = try reader.readBytes(count: offsetSize)
                let delta = signExtend(bytes: rawDeltaBytes)
                currentLCN += delta

                guard currentLCN >= 0 else {
                    throw NTFSError.corruptRunlist("Computed negative LCN: \(currentLCN)")
                }

                runs.append(DataRun(clusterCount: count, startingLCN: UInt64(currentLCN)))
            }
        }

        return runs
    }

    /// Sign-extends variable byte array (1 to 8 bytes, Little-Endian) into an `Int64`.
    public static func signExtend(bytes: Data) -> Int64 {
        guard !bytes.isEmpty else { return 0 }
        let count = bytes.count
        var val: UInt64 = 0
        for i in 0..<count {
            val |= (UInt64(bytes[bytes.startIndex + i]) << (i * 8))
        }

        // Check if most significant bit is set in the highest byte
        let msb = bytes[bytes.startIndex + count - 1] & 0x80
        if msb != 0 {
            // Sign-extend 1s into remaining higher bits
            let shift = count * 8
            if shift < 64 {
                let mask: UInt64 = (~0) << shift
                val |= mask
            }
        }

        return Int64(bitPattern: val)
    }
}
