import Foundation

/// Fast and safe Little-Endian binary stream reader for NTFS on-disk structures.
public struct BinaryReader: Sendable {
    public let data: Data
    public private(set) var offset: Int

    public var remainingBytes: Int {
        max(0, data.count - offset)
    }

    public var isEOF: Bool {
        offset >= data.count
    }

    public init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0 && newOffset <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(newOffset), requested: 0, available: data.count)
        }
        self.offset = newOffset
    }

    public mutating func skip(_ count: Int) throws {
        try seek(to: offset + count)
    }

    public mutating func readUInt8() throws -> UInt8 {
        guard offset + 1 <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: 1, available: data.count)
        }
        let val = data[data.startIndex + offset]
        offset += 1
        return val
    }

    public mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: 2, available: data.count)
        }
        let start = data.startIndex + offset
        let val = UInt16(data[start]) | (UInt16(data[start + 1]) << 8)
        offset += 2
        return val
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: 4, available: data.count)
        }
        let start = data.startIndex + offset
        let val = UInt32(data[start]) |
                 (UInt32(data[start + 1]) << 8) |
                 (UInt32(data[start + 2]) << 16) |
                 (UInt32(data[start + 3]) << 24)
        offset += 4
        return val
    }

    public mutating func readUInt64() throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: 8, available: data.count)
        }
        let start = data.startIndex + offset
        var val: UInt64 = 0
        for i in 0..<8 {
            val |= (UInt64(data[start + i]) << (i * 8))
        }
        offset += 8
        return val
    }

    public mutating func readInt64() throws -> Int64 {
        let u = try readUInt64()
        return Int64(bitPattern: u)
    }

    public mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0 && offset + count <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: count, available: data.count)
        }
        let start = data.startIndex + offset
        let slice = data.subdata(in: start..<(start + count))
        offset += count
        return slice
    }

    /// Read a fixed-length UTF-16LE string (character count, so byte count is count * 2)
    public mutating func readUTF16LEString(characterCount: Int) throws -> String {
        let byteCount = characterCount * 2
        let rawBytes = try readBytes(count: byteCount)
        var codeUnits = [UInt16]()
        codeUnits.reserveCapacity(characterCount)
        for i in stride(from: 0, to: byteCount, by: 2) {
            let u16 = UInt16(rawBytes[rawBytes.startIndex + i]) |
                     (UInt16(rawBytes[rawBytes.startIndex + i + 1]) << 8)
            codeUnits.append(u16)
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    /// Read fixed-length ASCII string
    public mutating func readASCIIString(byteCount: Int) throws -> String {
        let raw = try readBytes(count: byteCount)
        return String(decoding: raw, as: UTF8.self)
    }

    /// Peek without advancing offset
    public func peekUInt32() throws -> UInt32 {
        var copy = self
        return try copy.readUInt32()
    }

    public func peekBytes(count: Int) throws -> Data {
        var copy = self
        return try copy.readBytes(count: count)
    }
}
