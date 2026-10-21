import Foundation

/// Encodes DataRun items into an NTFS compressed runlist byte buffer.
public enum DataRunEncoder {
    /// Encodes an array of DataRun items into the raw NTFS runlist format.
    ///
    /// - Parameter runs: Array of DataRun items to encode.
    /// - Returns: Serialized runlist Data terminating with a 0x00 byte.
    public static func encode(runs: [DataRun]) -> Data {
        var result = Data()
        var previousLCN: Int64 = 0

        for run in runs {
            // Encode cluster count
            let lengthBytes = encodeUnsigned(value: run.clusterCount)
            let lengthSize = lengthBytes.count

            if let lcn = run.startingLCN {
                let currentLCN = Int64(lcn)
                let delta = currentLCN - previousLCN
                previousLCN = currentLCN

                let offsetBytes = encodeSigned(value: delta)
                let offsetSize = offsetBytes.count

                let header = UInt8((offsetSize << 4) | (lengthSize & 0x0F))
                result.append(header)
                result.append(lengthBytes)
                result.append(offsetBytes)
            } else {
                // Sparse run (offset size = 0)
                let header = UInt8(lengthSize & 0x0F)
                result.append(header)
                result.append(lengthBytes)
            }
        }

        // Runlist terminating byte
        result.append(0x00)
        return result
    }

    /// Determines minimum bytes needed for an unsigned 64-bit integer (1 to 8 bytes).
    public static func encodeUnsigned(value: UInt64) -> Data {
        if value == 0 {
            return Data([0x00])
        }

        var temp = value
        var bytes = [UInt8]()
        while temp > 0 {
            bytes.append(UInt8(temp & 0xFF))
            temp >>= 8
        }
        return Data(bytes)
    }

    /// Determines minimum bytes needed for a signed 64-bit integer with sign preservation.
    public static func encodeSigned(value: Int64) -> Data {
        if value >= -128 && value <= 127 {
            return Data([UInt8(bitPattern: Int8(value))])
        } else if value >= -32768 && value <= 32767 {
            var v = Int16(value).littleEndian
            return withUnsafeBytes(of: &v) { Data($0) }
        } else if value >= -8388608 && value <= 8388607 {
            let u = UInt32(bitPattern: Int32(value))
            return Data([
                UInt8(u & 0xFF),
                UInt8((u >> 8) & 0xFF),
                UInt8((u >> 16) & 0xFF)
            ])
        } else if value >= -2147483648 && value <= 2147483647 {
            var v = Int32(value).littleEndian
            return withUnsafeBytes(of: &v) { Data($0) }
        } else {
            var v = value.littleEndian
            return withUnsafeBytes(of: &v) { Data($0) }
        }
    }
}
