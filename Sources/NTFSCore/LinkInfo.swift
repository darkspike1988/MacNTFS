import Foundation

/// What a symbolic link, a junction or a similar link points to. MacNTFS reads the target but never follows it.
public struct LinkInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A Windows symbolic link (reparse tag 0xA000000C).
        case symlink
        /// A Windows junction, also called mount point (reparse tag 0xA0000003).
        case junction
        /// A Linux subsystem for Windows symbolic link (reparse tag 0xA000001D).
        case wslSymlink
        /// A link in the Interix format, as written by ntfs-3g: a system file whose content is the target.
        case interixSymlink
        /// Another reparse point, for example a cloud placeholder or a deduplicated file.
        case other(tag: UInt32)
    }

    public let kind: Kind
    /// The target as stored for the system (for example `\??\C:\target`).
    public let substituteName: String
    /// The target as meant for people (for example `C:\target`). Equal to `substituteName` if the link has no separate one.
    public let printName: String
    /// Raw flags of a Windows symbolic link. Bit 0 set means the target is relative to the link.
    public let flags: UInt32

    public var isRelative: Bool {
        kind == .symlink && flags & 1 != 0
    }

    /// The target to show to a person.
    public var target: String {
        printName.isEmpty ? substituteName : printName
    }
}

enum LinkParser {
    private static let tagSymlink: UInt32 = 0xA000_000C
    private static let tagMountPoint: UInt32 = 0xA000_0003
    private static let tagWSLSymlink: UInt32 = 0xA000_001D
    private static let interixMagic: [UInt8] = Array("IntxLNK".utf8) + [0x01]

    /// Largest Interix link content accepted: a path name and a few bytes.
    static let maxInterixSize = 64 * 1024

    /// Parses the value of a `$REPARSE_POINT` attribute.
    static func parseReparsePoint(_ data: Data) throws -> LinkInfo {
        var reader = BinaryReader(data: data)
        let tag = try reader.readUInt32()
        let dataLength = Int(try reader.readUInt16())
        try reader.skip(2)  // reserved
        guard 8 + dataLength <= data.count else {
            throw NTFSError.outOfBounds(offset: 0, requested: 8 + dataLength, available: data.count)
        }

        switch tag {
        case tagSymlink, tagMountPoint:
            let substituteOffset = Int(try reader.readUInt16())
            let substituteLength = Int(try reader.readUInt16())
            let printOffset = Int(try reader.readUInt16())
            let printLength = Int(try reader.readUInt16())
            let flags = tag == tagSymlink ? try reader.readUInt32() : 0
            let pathBuffer = reader.offset
            let end = 8 + dataLength

            func name(offset: Int, length: Int) throws -> String {
                guard length % 2 == 0, pathBuffer + offset + length <= end else {
                    throw NTFSError.outOfBounds(offset: UInt64(pathBuffer + offset), requested: length, available: end)
                }
                var nameReader = BinaryReader(data: data, offset: pathBuffer + offset)
                return try nameReader.readUTF16LEString(characterCount: length / 2)
            }
            let substitute = try name(offset: substituteOffset, length: substituteLength)
            let printed = try name(offset: printOffset, length: printLength)
            return LinkInfo(
                kind: tag == tagSymlink ? .symlink : .junction,
                substituteName: substitute,
                printName: printed.isEmpty ? substitute : printed,
                flags: flags
            )

        case tagWSLSymlink:
            _ = try reader.readUInt32()  // version
            let bytes = try reader.readBytes(count: max(0, 8 + dataLength - reader.offset))
            let target = String(decoding: bytes, as: UTF8.self)
            return LinkInfo(kind: .wslSymlink, substituteName: target, printName: target, flags: 0)

        default:
            return LinkInfo(kind: .other(tag: tag), substituteName: "", printName: "", flags: 0)
        }
    }

    /// Parses the content of an Interix link: the magic `IntxLNK` and 0x01, then the target in UTF-16.
    /// Returns nil if `content` is not such a link.
    static func parseInterixLink(_ content: Data) -> LinkInfo? {
        guard content.count > interixMagic.count,
              content.prefix(interixMagic.count).elementsEqual(interixMagic) else { return nil }
        let body = content.dropFirst(interixMagic.count)
        guard body.count % 2 == 0 else { return nil }
        var reader = BinaryReader(data: Data(body))
        guard let target = try? reader.readUTF16LEString(characterCount: body.count / 2) else { return nil }
        return LinkInfo(kind: .interixSymlink, substituteName: target, printName: target, flags: 0)
    }
}

extension NTFSVolume {
    /// The link at `path`, or nil if it is not a link. Does not follow the link.
    /// Recognizes Windows symbolic links, junctions, WSL links and Interix links.
    public func readLink(at path: String) throws -> LinkInfo? {
        let record = try lookup(path: path).record
        return try linkInfo(of: record)
    }

    func linkInfo(of record: MFTRecord) throws -> LinkInfo? {
        if let reparse = record.attribute(ofType: .reparsePoint) {
            guard let value = reparse.residentData else {
                return LinkInfo(kind: .other(tag: 0), substituteName: "", printName: "", flags: 0)
            }
            return try LinkParser.parseReparsePoint(value)
        }
        // Interix links are small files with no reparse point.
        guard !record.isDirectory,
              let data = record.defaultDataAttribute,
              data.realDataSize > 8, data.realDataSize <= UInt64(LinkParser.maxInterixSize) else { return nil }
        let content = try readData(record: record)
        return LinkParser.parseInterixLink(content)
    }
}
