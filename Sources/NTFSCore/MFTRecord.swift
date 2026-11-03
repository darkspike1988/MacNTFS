import Foundation

/// One data stream of a file. The default stream has no name.
public struct DataStream: Sendable, Equatable {
    public let name: String?
    public let size: UInt64
    public let isCompressed: Bool
    public let isEncrypted: Bool
}

public struct MFTRecord: Sendable {
    public let recordNumber: UInt64
    public let header: MFTRecordHeader
    public let attributes: [NTFSAttribute]
    /// False when the record has an `$ATTRIBUTE_LIST` whose extension records were not read.
    /// Records returned by `NTFSVolume` are always resolved.
    public let attributeListResolved: Bool

    public var hasUnresolvedAttributeList: Bool {
        !attributeListResolved
    }

    public var isInUse: Bool {
        header.isInUse
    }

    public var isDirectory: Bool {
        header.isDirectory
    }

    public init(recordNumber: UInt64, rawData: Data) throws {
        self.recordNumber = recordNumber

        var dataCopy = rawData
        let headerProbe = try MFTRecordHeader(data: dataCopy)

        // Apply Fixup Array to restore block ends and verify integrity
        try FixupApplier.applyFixup(
            data: &dataCopy,
            updateSequenceOffset: Int(headerProbe.updateSequenceOffset),
            updateSequenceSize: Int(headerProbe.updateSequenceSize)
        )

        // Re-read header from fixed data
        self.header = try MFTRecordHeader(data: dataCopy)

        var parsedAttributes = [NTFSAttribute]()
        var currentOffset = Int(self.header.firstAttributeOffset)

        while currentOffset + 16 <= dataCopy.count {
            let attr = try NTFSAttribute(data: dataCopy, offset: currentOffset)
            if attr.type == .endMarker || attr.recordLength == 0 {
                break
            }
            parsedAttributes.append(attr)
            currentOffset += Int(attr.recordLength)
        }

        self.attributes = parsedAttributes
        self.attributeListResolved = !parsedAttributes.contains { $0.type == .attributeList }
    }

    /// The base record with the attributes of its extension records merged in.
    init(resolving base: MFTRecord, attributes: [NTFSAttribute]) {
        self.recordNumber = base.recordNumber
        self.header = base.header
        self.attributes = attributes
        self.attributeListResolved = true
    }

    public func attribute(ofType type: AttributeType, name: String? = nil) -> NTFSAttribute? {
        attributes.first { attr in
            guard attr.type == type else { return false }
            if let name = name {
                return attr.name == name
            } else {
                return attr.name == nil
            }
        }
    }

    public func allAttributes(ofType type: AttributeType) -> [NTFSAttribute] {
        attributes.filter { $0.type == type }
    }

    public var standardInformation: StandardInformation? {
        guard let attr = attribute(ofType: .standardInformation),
              let resData = attr.residentData else { return nil }
        return try? StandardInformation(data: resData)
    }

    public var fileNames: [FileNameAttribute] {
        allAttributes(ofType: .fileName).compactMap { attr in
            guard let resData = attr.residentData else { return nil }
            return try? FileNameAttribute(data: resData)
        }
    }

    /// Primary filename, preferring Win32 or Win32/DOS namespace over pure DOS 8.3
    public var primaryFileName: FileNameAttribute? {
        let names = fileNames
        if let win32OrBoth = names.first(where: { $0.namespace == .win32 || $0.namespace == .win32AndDos }) {
            return win32OrBoth
        }
        if let posix = names.first(where: { $0.namespace == .posix }) {
            return posix
        }
        return names.first
    }

    public var defaultDataAttribute: NTFSAttribute? {
        attribute(ofType: .data, name: nil)
    }

    /// All data streams of the file: the unnamed default stream and the named ones.
    public var dataStreams: [DataStream] {
        attributes.filter { $0.type == .data }.map { attribute in
            DataStream(
                name: attribute.name,
                size: attribute.realDataSize,
                isCompressed: attribute.flags.contains(.compressed),
                isEncrypted: attribute.flags.contains(.encrypted)
            )
        }
    }

    /// The `$DATA` attribute of a named stream. An exact UTF-16 match wins over a case-insensitive one.
    public func dataStream(named name: String) -> NTFSAttribute? {
        let named = attributes.filter { $0.type == .data && $0.name != nil }
        return named.first { NTFSName.isExactMatch($0.name ?? "", name) }
            ?? named.first { NTFSName.isCaseInsensitiveMatch($0.name ?? "", name) }
    }
}
