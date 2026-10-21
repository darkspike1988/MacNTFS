import Foundation

public struct MFTRecord: Sendable {
    public let recordNumber: UInt64
    public let header: MFTRecordHeader
    public let attributes: [NTFSAttribute]

    public var isInUse: Bool {
        header.isInUse
    }

    public var isDirectory: Bool {
        header.isDirectory
    }

    public init(recordNumber: UInt64, rawData: Data, bytesPerSector: Int = 512) throws {
        self.recordNumber = recordNumber

        var dataCopy = rawData
        let headerProbe = try MFTRecordHeader(data: dataCopy)

        // Apply Fixup Array to restore sector ends and verify integrity
        try FixupApplier.applyFixup(
            data: &dataCopy,
            updateSequenceOffset: Int(headerProbe.updateSequenceOffset),
            updateSequenceSize: Int(headerProbe.updateSequenceSize),
            bytesPerSector: bytesPerSector
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
}
