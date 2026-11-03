import Foundation

public struct IndexEntryFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let hasSubNodes = IndexEntryFlags(rawValue: 0x0001)
    public static let lastEntry   = IndexEntryFlags(rawValue: 0x0002)
}

public struct IndexEntry: Sendable {
    public let mftRecordNumber: UInt64
    public let sequenceNumber: UInt16
    public let entryLength: UInt16
    public let streamLength: UInt16
    public let flags: IndexEntryFlags
    public let fileName: FileNameAttribute?
    public let subNodeVCN: UInt64?

    public var isLastEntry: Bool {
        flags.contains(.lastEntry)
    }

    public var hasSubNodes: Bool {
        flags.contains(.hasSubNodes)
    }
}

/// An index entry with positions instead of parsed values. Scanning a large directory with this
/// is much cheaper than building a `FileNameAttribute` (with dates and a string) for every entry.
struct RawIndexEntry {
    let mftRecordNumber: UInt64
    let entryLength: Int
    let flags: IndexEntryFlags
    /// Offset of the key (a `$FILE_NAME` structure) inside the data the entry was read from.
    let keyOffset: Int
    let keyLength: Int
    let subNodeVCN: UInt64?

    var isLastEntry: Bool { flags.contains(.lastEntry) }

    /// Size of a `$FILE_NAME` structure without its name: up to the namespace byte.
    private static let fileNameHeaderSize = 0x42

    var hasFileName: Bool { !isLastEntry && keyLength >= RawIndexEntry.fileNameHeaderSize }

    func nameLength(in data: Data) -> Int { Int(data[data.startIndex + keyOffset + 0x40]) }

    func namespace(in data: Data) -> FileNameNamespace {
        FileNameNamespace(rawValue: data[data.startIndex + keyOffset + 0x41]) ?? .win32
    }

    /// True if the name has the same UTF-16 code units as `units`. Does not allocate.
    func nameEquals(_ units: [UInt16], in data: Data) -> Bool {
        guard nameLength(in: data) == units.count,
              keyOffset + RawIndexEntry.fileNameHeaderSize + units.count * 2 <= keyOffset + keyLength else { return false }
        let start = data.startIndex + keyOffset + RawIndexEntry.fileNameHeaderSize
        for (index, unit) in units.enumerated() {
            let low = UInt16(data[start + index * 2])
            let high = UInt16(data[start + index * 2 + 1])
            if (high << 8 | low) != unit { return false }
        }
        return true
    }

    /// The full `$FILE_NAME` structure of the key.
    func fileName(in data: Data) throws -> FileNameAttribute {
        let start = data.startIndex + keyOffset
        return try FileNameAttribute(data: data.subdata(in: start..<(start + keyLength)))
    }
}

public enum IndexEntryParser {
    static func parseRaw(data: Data, offset: Int) throws -> RawIndexEntry {
        guard offset >= 0, offset + 16 <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(max(0, offset)), requested: 16, available: data.count)
        }

        var reader = BinaryReader(data: data, offset: offset)
        let rawRef = try reader.readUInt64()
        let entryLength = Int(try reader.readUInt16())
        guard entryLength >= 16 && offset + entryLength <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: entryLength, available: data.count)
        }

        let keyLength = Int(try reader.readUInt16())
        let flags = IndexEntryFlags(rawValue: try reader.readUInt16())
        guard 16 + keyLength <= entryLength else {
            throw NTFSError.outOfBounds(offset: UInt64(offset + 16), requested: keyLength, available: data.count)
        }

        var subNodeVCN: UInt64?
        if flags.contains(.hasSubNodes) {
            let vcnOffset = offset + entryLength - 8
            if vcnOffset >= offset + 16 {
                var vcnReader = BinaryReader(data: data, offset: vcnOffset)
                subNodeVCN = try? vcnReader.readUInt64()
            }
        }

        return RawIndexEntry(
            mftRecordNumber: rawRef & 0x0000_FFFF_FFFF_FFFF,
            entryLength: entryLength,
            flags: flags,
            keyOffset: offset + 16,
            keyLength: keyLength,
            subNodeVCN: subNodeVCN
        )
    }

    public static func parse(data: Data, offset: Int) throws -> IndexEntry {
        guard offset + 16 <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: 16, available: data.count)
        }

        var reader = BinaryReader(data: data, offset: offset)
        let rawRef = try reader.readUInt64()
        let mftRecordNumber = rawRef & 0x0000_FFFF_FFFF_FFFF
        let sequenceNumber = UInt16((rawRef >> 48) & 0xFFFF)

        let entryLength = try reader.readUInt16()
        guard entryLength >= 16 && offset + Int(entryLength) <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: Int(entryLength), available: data.count)
        }

        let streamLength = try reader.readUInt16()
        let flags = IndexEntryFlags(rawValue: try reader.readUInt16())
        let _ = try reader.readUInt16() // padding

        var parsedFileName: FileNameAttribute? = nil
        if !flags.contains(.lastEntry) && streamLength > 0 {
            let streamStart = offset + 16
            guard streamStart + Int(streamLength) <= offset + Int(entryLength) else {
                throw NTFSError.outOfBounds(offset: UInt64(streamStart), requested: Int(streamLength), available: data.count)
            }
            let streamData = data.subdata(in: streamStart..<(streamStart + Int(streamLength)))
            parsedFileName = try? FileNameAttribute(data: streamData)
        }

        var subNodeVCN: UInt64? = nil
        if flags.contains(.hasSubNodes) {
            let vcnOffset = offset + Int(entryLength) - 8
            if vcnOffset >= offset && vcnOffset + 8 <= data.count {
                var vcnReader = BinaryReader(data: data, offset: vcnOffset)
                subNodeVCN = try? vcnReader.readUInt64()
            }
        }

        return IndexEntry(
            mftRecordNumber: mftRecordNumber,
            sequenceNumber: sequenceNumber,
            entryLength: entryLength,
            streamLength: streamLength,
            flags: flags,
            fileName: parsedFileName,
            subNodeVCN: subNodeVCN
        )
    }
}
