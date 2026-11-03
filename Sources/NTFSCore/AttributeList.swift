import Foundation

/// One entry of an `$ATTRIBUTE_LIST`: where an attribute of a file is stored.
struct AttributeListEntry: Sendable, Equatable {
    let type: AttributeType
    let name: String?
    let startingVCN: UInt64
    /// The MFT record that holds the attribute. It can be the base record itself.
    let recordNumber: UInt64
    let attributeID: UInt16
}

enum AttributeListParser {
    /// Largest attribute list accepted. Real lists are a few kilobytes.
    static let maxEntries = 100_000

    /// Minimum size of an entry: the fixed header up to the attribute ID.
    private static let headerSize = 0x1A

    static func parse(_ data: Data) throws -> [AttributeListEntry] {
        var entries = [AttributeListEntry]()
        var offset = 0

        while offset + headerSize <= data.count {
            var reader = BinaryReader(data: data, offset: offset)
            let rawType = try reader.readUInt32()
            let length = Int(try reader.readUInt16())
            let nameLength = Int(try reader.readUInt8())
            let nameOffset = Int(try reader.readUInt8())
            let startingVCN = try reader.readUInt64()
            let reference = try reader.readUInt64()
            let attributeID = try reader.readUInt16()

            // Padding after the last entry reads as zeros.
            if length == 0 { break }
            guard length >= headerSize, offset + length <= data.count else {
                throw NTFSError.corruptAttributeList("Entry at offset \(offset) has length \(length)")
            }

            var name: String?
            if nameLength > 0 {
                guard nameOffset >= headerSize, nameOffset + nameLength * 2 <= length else {
                    throw NTFSError.corruptAttributeList("Entry at offset \(offset) has an invalid name")
                }
                var nameReader = BinaryReader(data: data, offset: offset + nameOffset)
                name = try nameReader.readUTF16LEString(characterCount: nameLength)
            }

            entries.append(AttributeListEntry(
                type: AttributeType(rawValue: rawType),
                name: name,
                startingVCN: startingVCN,
                recordNumber: reference & 0x0000_FFFF_FFFF_FFFF,
                attributeID: attributeID
            ))
            guard entries.count <= maxEntries else {
                throw NTFSError.resourceLimit("Attribute list has more than \(maxEntries) entries")
            }
            offset += length
        }
        return entries
    }
}

/// Joins the extents of a non-resident attribute that NTFS split over several records.
enum AttributeMerger {
    private struct Key: Hashable {
        let type: UInt32
        let name: [UInt16]
    }

    /// Returns the attributes with all extents of the same (type, name) combined into one attribute.
    /// The first extent holds the sizes. The run lists are joined in VCN order.
    static func merge(_ attributes: [NTFSAttribute]) throws -> [NTFSAttribute] {
        var result = [NTFSAttribute]()
        var firstPosition = [Key: Int]()
        var extents = [Int: [NTFSAttribute]]()

        for attribute in attributes {
            if attribute.isNonResident && attribute.type != .endMarker {
                let key = Key(type: attribute.type.rawValue, name: Array((attribute.name ?? "").utf16))
                if let position = firstPosition[key] {
                    extents[position, default: []].append(attribute)
                    continue
                }
                firstPosition[key] = result.count
                extents[result.count] = [attribute]
            }
            result.append(attribute)
        }

        for (position, group) in extents where group.count > 1 {
            result[position] = try combine(group)
        }
        return result
    }

    private static func combine(_ extents: [NTFSAttribute]) throws -> NTFSAttribute {
        let sorted = extents.sorted { $0.startingVCN < $1.startingVCN }
        guard let first = sorted.first, case .nonResident(let firstVCN, _, let allocated, let real, let initialized, _) = first.payload,
              let last = sorted.last, case .nonResident(_, let lastEndVCN, _, _, _, _) = last.payload else {
            throw NTFSError.corruptAttributeList("Attribute extents are not non-resident")
        }
        guard firstVCN == 0 else {
            throw NTFSError.corruptAttributeList("The first extent of \(first.type) starts at VCN \(firstVCN)")
        }

        var nextVCN: UInt64 = 0
        var runs = [DataRun]()
        for extent in sorted {
            guard case .nonResident(let startVCN, _, _, _, _, let extentRuns) = extent.payload, startVCN == nextVCN else {
                throw NTFSError.corruptAttributeList("The extents of \(first.type) are not contiguous at VCN \(nextVCN)")
            }
            for run in extentRuns {
                let (sum, overflow) = nextVCN.addingReportingOverflow(run.clusterCount)
                guard !overflow else { throw NTFSError.corruptRunlist("Run list size overflows") }
                nextVCN = sum
            }
            runs.append(contentsOf: extentRuns)
        }

        // The extents must cover everything up to the end of the last one, or a part is missing.
        guard nextVCN == lastEndVCN &+ 1 else {
            throw NTFSError.corruptAttributeList("The extents of \(first.type) cover \(nextVCN) clusters, but the last one ends at VCN \(lastEndVCN)")
        }

        return NTFSAttribute(
            type: first.type,
            recordLength: first.recordLength,
            isNonResident: true,
            name: first.name,
            flags: first.flags,
            attributeID: first.attributeID,
            payload: .nonResident(
                startingVCN: 0,
                endingVCN: lastEndVCN,
                allocatedSize: allocated,
                realSize: real,
                initializedSize: initialized,
                runs: runs
            ),
            compressionUnitShift: first.compressionUnitShift
        )
    }
}
