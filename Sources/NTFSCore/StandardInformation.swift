import Foundation

public struct FileTimeConverter {
    /// Converts Windows FILETIME (100-nanosecond intervals since January 1, 1601 UTC) to Swift `Date`.
    public static func toDate(fileTime: UInt64) -> Date {
        // Difference between 1601-01-01 and 1970-01-01 in 100-nanosecond intervals:
        // 11644473600 seconds * 10,000,000 = 116444736000000000
        let intervalsTo1970: UInt64 = 116_444_736_000_000_000
        guard fileTime >= intervalsTo1970 else {
            return Date(timeIntervalSince1970: 0)
        }
        let intervalsSince1970 = fileTime - intervalsTo1970
        let seconds = Double(intervalsSince1970) / 10_000_000.0
        return Date(timeIntervalSince1970: seconds)
    }

    /// Converts Swift `Date` to Windows FILETIME.
    public static func toFileTime(date: Date) -> UInt64 {
        let intervalsTo1970: UInt64 = 116_444_736_000_000_000
        let secondsSince1970 = date.timeIntervalSince1970
        if secondsSince1970 < 0 {
            return 0
        }
        let intervalsSince1970 = UInt64(secondsSince1970 * 10_000_000.0)
        return intervalsTo1970 + intervalsSince1970
    }
}

public struct StandardInformation: Sendable {
    public let creationTime: Date
    public let modificationTime: Date
    public let mftModificationTime: Date
    public let accessTime: Date
    public let dosFlags: UInt32

    public init(data: Data) throws {
        guard data.count >= 48 else {
            throw NTFSError.outOfBounds(offset: 0, requested: 48, available: data.count)
        }
        var reader = BinaryReader(data: data)
        self.creationTime = FileTimeConverter.toDate(fileTime: try reader.readUInt64())
        self.modificationTime = FileTimeConverter.toDate(fileTime: try reader.readUInt64())
        self.mftModificationTime = FileTimeConverter.toDate(fileTime: try reader.readUInt64())
        self.accessTime = FileTimeConverter.toDate(fileTime: try reader.readUInt64())
        self.dosFlags = try reader.readUInt32()
    }
}
