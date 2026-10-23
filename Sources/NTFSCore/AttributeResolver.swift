import Foundation

/// Large or heavily fragmented files keep attributes in extension records listed by
/// $ATTRIBUTE_LIST, and one stream may be split into several extents. Readers work on
/// the joined logical view; writers keep refusing such records.
extension NTFSVolume {
    struct AttributeListEntry: Equatable {
        let type: UInt32
        let name: String?
        let lowestVCN: UInt64
        let recordNumber: UInt64
        let instance: UInt16
    }

    static func parseAttributeList(_ data: Data) throws -> [AttributeListEntry] {
        let bytes = [UInt8](data)
        func u16(_ p: Int) -> UInt16 { UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8 }
        func u32(_ p: Int) -> UInt32 { UInt32(u16(p)) | UInt32(u16(p + 2)) << 16 }
        func u64(_ p: Int) -> UInt64 { UInt64(u32(p)) | UInt64(u32(p + 4)) << 32 }
        var entries: [AttributeListEntry] = []
        var offset = 0
        while offset + 26 <= bytes.count {
            let length = Int(u16(offset + 4))
            guard length >= 26, offset + length <= bytes.count else {
                throw NTFSError.corruptRunlist("Invalid $ATTRIBUTE_LIST entry length")
            }
            let nameLength = Int(bytes[offset + 6]), nameOffset = Int(bytes[offset + 7])
            var name: String?
            if nameLength > 0 {
                guard offset + nameOffset + nameLength * 2 <= offset + length else {
                    throw NTFSError.corruptRunlist("Invalid $ATTRIBUTE_LIST entry name")
                }
                let units = (0..<nameLength).map { u16(offset + nameOffset + $0 * 2) }
                name = String(decoding: units, as: UTF16.self)
            }
            entries.append(AttributeListEntry(type: u32(offset), name: name, lowestVCN: u64(offset + 8),
                                              recordNumber: u64(offset + 16) & 0x0000_FFFF_FFFF_FFFF,
                                              instance: u16(offset + 24)))
            offset += length
        }
        return entries
    }

    /// Returns the value of a resident or non-resident attribute.
    func attributeValue(_ attr: NTFSAttribute) throws -> Data {
        if let data = attr.residentData { return data }
        guard let runs = attr.runs, attr.flags.isEmpty else {
            throw NTFSError.unsupportedFeature("Encoded attribute value")
        }
        guard let data = try Self.readFromRuns(runs: runs, virtualOffset: 0, length: Int(attr.realDataSize),
                                               bootSector: bootSector, device: blockDevice) else {
            throw NTFSError.outOfBounds(offset: 0, requested: Int(attr.realDataSize), available: 0)
        }
        return data
    }

    /// Joins attributes from extension records and merges multi-extent streams.
    public func resolvedRecord(_ record: MFTRecord) throws -> MFTRecord {
        var attributes = record.attributes
        let list = record.attribute(ofType: .attributeList)
        if let list {
            var holders: [UInt64: MFTRecord] = [record.recordNumber: record]
            var gathered = [list]
            for entry in try Self.parseAttributeList(attributeValue(list))
            where entry.type != AttributeType.attributeList.rawValue {
                let holder: MFTRecord
                if let cached = holders[entry.recordNumber] {
                    holder = cached
                } else {
                    holder = try readMFTRecord(number: entry.recordNumber)
                    guard holder.isInUse else { throw NTFSError.recordNotAllocated(recordNumber: entry.recordNumber) }
                    holders[entry.recordNumber] = holder
                }
                guard let attr = holder.attributes.first(where: {
                    $0.type.rawValue == entry.type && $0.attributeID == entry.instance && $0.name == entry.name
                }) else {
                    throw NTFSError.corruptRunlist("$ATTRIBUTE_LIST references a missing attribute")
                }
                gathered.append(attr)
            }
            attributes = gathered
        }
        var keys: [String] = []
        var groups: [String: [NTFSAttribute]] = [:]
        var merged: [NTFSAttribute] = []
        for attr in attributes {
            guard attr.isNonResident else { merged.append(attr); continue }
            let key = "\(attr.type.rawValue)/\(attr.name ?? "")"
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(attr)
        }
        guard list != nil || groups.values.contains(where: { $0.count > 1 }) else { return record }
        for key in keys {
            let extents = groups[key]!
            merged.append(extents.count == 1 ? extents[0] : try NTFSAttribute(merging: extents))
        }
        merged.sort { $0.type.rawValue < $1.type.rawValue }
        return MFTRecord(resolving: record, attributes: merged)
    }

    /// $MFT's own $DATA can be split across extension records on large volumes.
    /// Extension records are always reachable through the extents gathered before them.
    static func mftRuns(base: MFTRecord, bootSector: BootSector, device: BlockDevice) throws -> [DataRun] {
        var extents = base.attributes.filter { $0.type == .data && $0.name == nil && $0.isNonResident }
        guard !extents.isEmpty else {
            throw NTFSError.corruptRunlist("$MFT record 0 does not contain non-resident $DATA runs")
        }
        var runs = try NTFSAttribute(merging: extents).runs ?? []
        guard let list = base.attribute(ofType: .attributeList) else { return runs }
        let listData: Data
        if let resident = list.residentData {
            listData = resident
        } else if let listRuns = list.runs, let data = try readFromRuns(runs: listRuns, virtualOffset: 0,
                                                                        length: Int(list.realDataSize),
                                                                        bootSector: bootSector, device: device) {
            listData = data
        } else {
            throw NTFSError.corruptRunlist("Unreadable $MFT attribute list")
        }
        for entry in try parseAttributeList(listData)
        where entry.type == AttributeType.data.rawValue && entry.name == nil && entry.recordNumber != 0 {
            let holder = try readRecord(recordNumber: entry.recordNumber, runs: runs, bootSector: bootSector, device: device)
            let instance = entry.instance
            let match = holder.attributes.first { (attr: NTFSAttribute) -> Bool in
                attr.type == .data && attr.name == nil && attr.attributeID == instance
            }
            guard let attr = match else {
                throw NTFSError.corruptRunlist("$MFT extent record is missing its $DATA extent")
            }
            extents.append(attr)
            runs = try NTFSAttribute(merging: extents).runs ?? []
        }
        return runs
    }
}
