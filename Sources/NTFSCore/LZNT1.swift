import Foundation

/// The LZNT1 compression NTFS uses for compressed files.
/// A stream is a sequence of chunks. Each chunk expands to at most 4096 bytes and starts with a
/// 2-byte header: bit 15 says the chunk is compressed, bits 14 to 12 are 3, and the low 12 bits are the
/// size of the chunk data minus one. A header of zero ends the stream.
enum LZNT1 {
    static let maxChunkOutput = 4096

    /// Expands `input`. Throws if the data is damaged or would expand to more than `maxOutput` bytes.
    static func decompress(_ data: Data, maxOutput: Int) throws -> Data {
        let input = [UInt8](data)
        var output = [UInt8]()
        output.reserveCapacity(min(maxOutput, 1 << 20))
        var position = 0

        while position + 2 <= input.count {
            let header = Int(input[position]) | (Int(input[position + 1]) << 8)
            if header == 0 { break }
            guard header & 0x7000 == 0x3000 else {
                throw NTFSError.corruptCompressedData("Chunk header 0x\(String(header, radix: 16)) has a wrong signature")
            }
            // Every chunk expands to 4096 bytes, except the last one of the stream. A shorter chunk
            // before another one is padded with zeros, as ntfs-3g does.
            if output.count % maxChunkOutput != 0 {
                output.append(contentsOf: [UInt8](repeating: 0, count: maxChunkOutput - output.count % maxChunkOutput))
            }
            let chunkSize = (header & 0x0FFF) + 1
            let start = position + 2
            let end = start + chunkSize
            guard end <= input.count else {
                throw NTFSError.corruptCompressedData("A chunk of \(chunkSize) bytes runs past the end of the data")
            }

            if header & 0x8000 == 0 {
                output.append(contentsOf: input[start..<end])
            } else {
                try expandChunk(input, from: start, to: end, into: &output)
            }
            guard output.count <= maxOutput else {
                throw NTFSError.corruptCompressedData("The data expands to more than \(maxOutput) bytes")
            }
            position = end
        }
        return Data(output)
    }

    private static func expandChunk(_ input: [UInt8], from start: Int, to end: Int, into output: inout [UInt8]) throws {
        let chunkStart = output.count
        var index = start

        while index < end {
            let flags = input[index]
            index += 1
            var bit = 0
            while bit < 8 && index < end {
                if flags & (1 << UInt8(bit)) == 0 {
                    output.append(input[index])
                    index += 1
                } else {
                    guard index + 2 <= end else {
                        throw NTFSError.corruptCompressedData("A back reference is cut off")
                    }
                    let token = Int(input[index]) | (Int(input[index + 1]) << 8)
                    index += 2

                    // The split between offset bits and length bits depends on how much of the chunk is already written.
                    let produced = output.count - chunkStart
                    guard produced > 0 else {
                        throw NTFSError.corruptCompressedData("A back reference at the start of a chunk")
                    }
                    var lengthMask = 0x0FFF
                    var displacementShift = 12
                    var rest = produced - 1
                    while rest >= 0x10 {
                        lengthMask >>= 1
                        displacementShift -= 1
                        rest >>= 1
                    }
                    let length = (token & lengthMask) + 3
                    let displacement = (token >> displacementShift) + 1
                    guard displacement <= produced else {
                        throw NTFSError.corruptCompressedData("A back reference points \(displacement) bytes back, but only \(produced) exist")
                    }
                    guard produced + length <= maxChunkOutput else {
                        throw NTFSError.corruptCompressedData("A chunk expands to more than \(maxChunkOutput) bytes")
                    }
                    let from = output.count - displacement
                    for offset in 0..<length {
                        output.append(output[from + offset])  // may overlap the bytes being written
                    }
                }
                bit += 1
                guard output.count - chunkStart <= maxChunkOutput else {
                    throw NTFSError.corruptCompressedData("A chunk expands to more than \(maxChunkOutput) bytes")
                }
            }
        }
    }
}
