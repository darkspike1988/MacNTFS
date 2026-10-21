import Foundation

public enum FileNameNamespace: UInt8, Sendable {
    case posix = 0
    case win32 = 1
    case dos = 2
    case win32AndDos = 3
}

public struct FileNameAttribute: Sendable {
    public let parentDirectoryRecordNumber: UInt64
    public let parentDirectorySequenceNumber: UInt16
    public let creationTime: Date
    public let modificationTime: Date
    public let mftModificationTime: Date
    public let accessTime: Date
    public let allocatedSize: UInt64
    public let realSize: UInt64
    public let flags: UInt32
    public let namespace: FileNameNamespace
    public let name: String

    public var isDirectory: Bool {
        (flags & 0x10000000) != 0 || (flags & 0x00000010) != 0
    }

    public init(data: Data) throws {
        guard data.count >= 66 else {
            throw NTFSError.outOfBounds(offset: 0, requested: 66, available: data.count)
        }

        var reader = BinaryReader(data: data)

        // Parent directory reference (48-bit record number, 16-bit sequence number)
        let rawParentRef = try reader.readUInt64()
        self.parentDirectoryRecordNumber = rawParentRef & 0x0000_FFFF_FFFF_FFFF
        self.parentDirectorySequenceNumber = UInt16((rawParentRef >> 48) & 0xFFFF)

        self.creationTime = FileTimeConverter.toDate(fileTime: try reader.readUInt64())
        self.modificationTime = FileTimeConverter.toDate(fileTime: try reader.readUInt64())
        self.mftModificationTime = FileTimeConverter.toDate(fileTime: try reader.readUInt64())
        self.accessTime = FileTimeConverter.toDate(fileTime: try reader.readUInt64())

        self.allocatedSize = try reader.readUInt64()
        self.realSize = try reader.readUInt64()
        self.flags = try reader.readUInt32()
        let _ = try reader.readUInt32() // Reparse / EA

        let nameLength = Int(try reader.readUInt8())
        let rawNamespace = try reader.readUInt8()
        self.namespace = FileNameNamespace(rawValue: rawNamespace) ?? .win32

        guard reader.remainingBytes >= nameLength * 2 else {
            throw NTFSError.outOfBounds(offset: UInt64(reader.offset), requested: nameLength * 2, available: reader.remainingBytes)
        }
        self.name = try reader.readUTF16LEString(characterCount: nameLength)
    }
}
