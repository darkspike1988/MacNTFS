import Foundation

public struct MFTRecordFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let inUse     = MFTRecordFlags(rawValue: 0x0001)
    public static let directory = MFTRecordFlags(rawValue: 0x0002)
}

public struct MFTRecordHeader: Sendable {
    public let magic: String
    public let updateSequenceOffset: UInt16
    public let updateSequenceSize: UInt16
    public let logFileSequenceNumber: UInt64
    public let sequenceNumber: UInt16
    public let hardLinkCount: UInt16
    public let firstAttributeOffset: UInt16
    public let flags: MFTRecordFlags
    public let usedSize: UInt32
    public let allocatedSize: UInt32
    public let baseRecordReference: UInt64
    public let nextAttributeID: UInt16
    public let recordNumber: UInt32

    public var isInUse: Bool {
        flags.contains(.inUse)
    }

    public var isDirectory: Bool {
        flags.contains(.directory)
    }

    public init(data: Data) throws {
        guard data.count >= 48 else {
            throw NTFSError.outOfBounds(offset: 0, requested: 48, available: data.count)
        }

        var reader = BinaryReader(data: data)
        let magic = try reader.readASCIIString(byteCount: 4)
        guard magic == "FILE" || magic == "BAAD" else {
            throw NTFSError.invalidSignature(expected: "FILE", found: magic)
        }
        self.magic = magic

        self.updateSequenceOffset = try reader.readUInt16()
        self.updateSequenceSize = try reader.readUInt16()
        self.logFileSequenceNumber = try reader.readUInt64()
        self.sequenceNumber = try reader.readUInt16()
        self.hardLinkCount = try reader.readUInt16()
        self.firstAttributeOffset = try reader.readUInt16()
        self.flags = MFTRecordFlags(rawValue: try reader.readUInt16())
        self.usedSize = try reader.readUInt32()
        self.allocatedSize = try reader.readUInt32()
        self.baseRecordReference = try reader.readUInt64()
        self.nextAttributeID = try reader.readUInt16()

        // NTFS 3.1+ fields
        if reader.remainingBytes >= 6 {
            try reader.skip(2) // align
            self.recordNumber = try reader.readUInt32()
        } else {
            self.recordNumber = 0
        }
    }
}
