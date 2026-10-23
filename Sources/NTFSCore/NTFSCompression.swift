import Foundation

/// Read support for NTFS-compressed streams (LZNT1, as documented in [MS-XCA] 2.5).
/// A stream is divided into compression units of 2^n clusters. A unit whose clusters are
/// all allocated is stored raw; one followed by a sparse tail holds LZNT1 data; an
/// entirely sparse unit reads as zeros.
enum NTFSCompression {
    static let chunkSize = 4096

    static func decompressLZNT1(_ input: ArraySlice<UInt8>, outputSize: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(outputSize)
        var p = input.startIndex
        while p + 2 <= input.endIndex, out.count < outputSize {
            let header = Int(input[p]) | Int(input[p + 1]) << 8
            if header == 0 { break }
            let start = p + 2, end = start + (header & 0x0FFF) + 1
            guard end <= input.endIndex else { throw NTFSError.corruptRunlist("Truncated LZNT1 chunk") }
            let chunkStart = out.count
            if header & 0x8000 == 0 {
                out.append(contentsOf: input[start..<end])
            } else {
                var q = start
                while q < end {
                    let flags = input[q]
                    q += 1
                    for bit in 0..<8 {
                        guard q < end else { break }
                        if flags & (1 << bit) == 0 {
                            out.append(input[q])
                            q += 1
                            continue
                        }
                        guard q + 1 < end else { throw NTFSError.corruptRunlist("Truncated LZNT1 token") }
                        let token = Int(input[q]) | Int(input[q + 1]) << 8
                        q += 2
                        let position = out.count - chunkStart
                        guard position > 0 else { throw NTFSError.corruptRunlist("LZNT1 back-reference before data") }
                        var lengthMask = 0x0FFF, displacementShift = 12
                        var i = position - 1
                        while i >= 0x10 { lengthMask >>= 1; displacementShift -= 1; i >>= 1 }
                        let displacement = (token >> displacementShift) + 1
                        let length = (token & lengthMask) + 3
                        guard displacement <= position, position + length <= chunkSize else {
                            throw NTFSError.corruptRunlist("Invalid LZNT1 back-reference")
                        }
                        let from = out.count - displacement
                        for k in 0..<length { out.append(out[from + k]) } // Overlapping copies repeat bytes.
                    }
                }
            }
            guard out.count - chunkStart <= chunkSize else { throw NTFSError.corruptRunlist("Oversized LZNT1 chunk") }
            // Every chunk stands for a full 4 KiB of uncompressed data.
            out.append(contentsOf: repeatElement(0, count: chunkSize - (out.count - chunkStart)))
            p = end
        }
        if out.count < outputSize { out.append(contentsOf: repeatElement(0, count: outputSize - out.count)) }
        return Array(out.prefix(outputSize))
    }

    /// Reads `length` bytes of the logical (uncompressed) stream at `offset`.
    static func read(runs: [DataRun], compressionUnit: UInt8, offset: UInt64, length: Int,
                     cluster: UInt64, device: BlockDevice) throws -> Data {
        guard length > 0 else { return Data() }
        guard compressionUnit > 0, compressionUnit <= 8, cluster <= 4096 else {
            throw NTFSError.unsupportedFeature("Unsupported NTFS compression unit")
        }
        let unitClusters = UInt64(1) << UInt64(compressionUnit)
        let unitBytes = unitClusters * cluster
        // Flatten to (vcn, count, lcn) for range queries.
        var map: [(vcn: UInt64, count: UInt64, lcn: UInt64?)] = []
        var vcn: UInt64 = 0
        for run in runs { map.append((vcn, run.clusterCount, run.startingLCN)); vcn += run.clusterCount }

        var result = Data()
        result.reserveCapacity(length)
        var unit = offset / unitBytes
        let end = offset + UInt64(length)
        while unit * unitBytes < end {
            let first = unit * unitClusters
            // Allocated clusters of this unit, in VCN order, until the first sparse or unmapped cluster.
            var pieces: [(lcn: UInt64, count: UInt64)] = []
            var allocated: UInt64 = 0
            var cursor = first
            scan: for entry in map where entry.vcn + entry.count > cursor && entry.vcn < first + unitClusters {
                guard entry.vcn <= cursor else { break scan }
                let take = min(entry.vcn + entry.count, first + unitClusters) - cursor
                guard let lcn = entry.lcn else { break scan }
                pieces.append((lcn + (cursor - entry.vcn), take))
                allocated += take
                cursor += take
            }
            var raw = Data()
            for piece in pieces { raw.append(try device.read(offset: piece.lcn * cluster, count: Int(piece.count * cluster))) }
            let plain: Data
            if allocated == unitClusters {
                plain = raw
            } else if allocated == 0 {
                plain = Data(count: Int(unitBytes))
            } else {
                let bytes = [UInt8](raw)
                plain = Data(try decompressLZNT1(bytes[...], outputSize: Int(unitBytes)))
            }
            let unitStart = unit * unitBytes
            let from = max(offset, unitStart) - unitStart
            let to = min(end, unitStart + unitBytes) - unitStart
            result.append(plain.subdata(in: Int(from)..<Int(to)))
            unit += 1
        }
        return result
    }
}
