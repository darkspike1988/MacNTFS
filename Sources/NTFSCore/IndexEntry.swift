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

public enum IndexEntryParser {
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
