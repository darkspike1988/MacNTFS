import Foundation

public struct DirectoryItem: Identifiable, Hashable, Sendable {
    public var id: UInt64 { mftRecordNumber }
    public let name: String
    public let mftRecordNumber: UInt64
    public let isDirectory: Bool
    public let fileSize: UInt64
    public let modificationDate: Date
    public let creationDate: Date

    public func hash(into hasher: inout Hasher) {
        hasher.combine(mftRecordNumber)
        hasher.combine(name)
    }

    public static func == (lhs: DirectoryItem, rhs: DirectoryItem) -> Bool {
        lhs.mftRecordNumber == rhs.mftRecordNumber && lhs.name == rhs.name
    }
}

public final class DirectoryIndexReader: Sendable {
    private let blockDevice: BlockDevice
    private let bootSector: BootSector

    /// B-trees of real directories are a few levels deep. A deeper chain means a damaged or hostile index.
    private static let maxIndexDepth = 32

    public init(blockDevice: BlockDevice, bootSector: BootSector) {
        self.blockDevice = blockDevice
        self.bootSector = bootSector
    }

    /// Reads all directory entries from an MFT record representing a directory.
    /// Pure DOS 8.3 entries are skipped, because they always come with a Win32 entry for the same file.
    /// Hard links keep one item per name.
    public func readEntries(from record: MFTRecord) throws -> [DirectoryItem] {
        var items = [DirectoryItem]()
        try walk(record) { item in
            items.append(item)
            return false
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Finds one entry by name without reading the whole directory into a sorted list.
    /// An exact match on the UTF-16 name wins over a case-insensitive match.
    public func findEntry(named name: String, in record: MFTRecord) throws -> DirectoryItem? {
        var exact: DirectoryItem?
        var caseInsensitive: DirectoryItem?
        try walk(record) { item in
            if NTFSName.isExactMatch(item.name, name) {
                exact = item
                return true
            }
            if caseInsensitive == nil && NTFSName.isCaseInsensitiveMatch(item.name, name) {
                caseInsensitive = item
            }
            return false
        }
        return exact ?? caseInsensitive
    }

    /// Visits every entry of a directory. `visit` returns true to stop early.
    private func walk(_ record: MFTRecord, visit: (DirectoryItem) -> Bool) throws {
        guard record.isDirectory else {
            throw NTFSError.notADirectory("Record \(record.recordNumber) is not a directory")
        }
        // The index may live in extension records that are not read, and a link target is not this directory.
        if record.attribute(ofType: .attributeList) != nil {
            throw NTFSError.unsupported(.attributeList)
        }
        if record.attribute(ofType: .reparsePoint) != nil {
            throw NTFSError.unsupported(.reparse)
        }
        guard let indexRootAttr = record.attribute(ofType: .indexRoot, name: "$I30"),
              let indexRootData = indexRootAttr.residentData else {
            throw NTFSError.attributeNotFound(type: AttributeType.indexRoot.rawValue, name: "$I30")
        }

        let indexAllocAttr = record.attribute(ofType: .indexAllocation, name: "$I30")
        var visitedVCNs = Set<UInt64>()
        // The node header of $INDEX_ROOT starts at offset 0x10.
        _ = try parseNode(
            data: indexRootData,
            nodeHeaderOffset: 16,
            indexAlloc: indexAllocAttr,
            depth: 0,
            visitedVCNs: &visitedVCNs,
            visit: visit
        )
    }

    /// Returns true if `visit` asked to stop.
    private func parseNode(
        data: Data,
        nodeHeaderOffset: Int,
        indexAlloc: NTFSAttribute?,
        depth: Int,
        visitedVCNs: inout Set<UInt64>,
        visit: (DirectoryItem) -> Bool
    ) throws -> Bool {
        guard data.count >= nodeHeaderOffset + 16 else {
            throw NTFSError.corruptDirectoryIndex("Index node header is too short")
        }

        var reader = BinaryReader(data: data, offset: nodeHeaderOffset)
        let firstEntryOffset = Int(try reader.readUInt32())
        let totalEntriesSize = Int(try reader.readUInt32())

        var currentOffset = nodeHeaderOffset + firstEntryOffset
        let limitOffset = nodeHeaderOffset + totalEntriesSize

        while currentOffset < limitOffset && currentOffset + 16 <= data.count {
            let entry = try IndexEntryParser.parse(data: data, offset: currentOffset)

            if let fn = entry.fileName, fn.name != ".", fn.namespace != .dos {
                let item = DirectoryItem(
                    name: fn.name,
                    mftRecordNumber: entry.mftRecordNumber,
                    isDirectory: fn.isDirectory,
                    fileSize: fn.realSize,
                    modificationDate: fn.modificationTime,
                    creationDate: fn.creationTime
                )
                if visit(item) { return true }
            }

            if let vcn = entry.subNodeVCN {
                guard let alloc = indexAlloc else {
                    throw NTFSError.corruptDirectoryIndex("Index entry points to sub-node \(vcn), but the directory has no $INDEX_ALLOCATION")
                }
                if try parseIndexBlock(vcn: vcn, indexAlloc: alloc, depth: depth + 1, visitedVCNs: &visitedVCNs, visit: visit) {
                    return true
                }
            }

            if entry.isLastEntry || entry.entryLength == 0 {
                break
            }
            currentOffset += Int(entry.entryLength)
        }
        return false
    }

    /// Returns true if `visit` asked to stop.
    private func parseIndexBlock(
        vcn: UInt64,
        indexAlloc: NTFSAttribute,
        depth: Int,
        visitedVCNs: inout Set<UInt64>,
        visit: (DirectoryItem) -> Bool
    ) throws -> Bool {
        guard !visitedVCNs.contains(vcn) else { return false }
        visitedVCNs.insert(vcn)

        guard depth <= DirectoryIndexReader.maxIndexDepth else {
            throw NTFSError.corruptDirectoryIndex("Index nesting deeper than \(DirectoryIndexReader.maxIndexDepth) levels")
        }
        guard let runs = indexAlloc.runs else {
            throw NTFSError.corruptDirectoryIndex("$INDEX_ALLOCATION is resident")
        }

        let indexRecordSize = Int(bootSector.indexRecordSizeBytes)
        let clusterSize = UInt64(bootSector.clusterSizeBytes)

        // The VCN of an index block counts clusters, or 512-byte units when a cluster is larger than an index block.
        let vcnUnit: UInt64 = clusterSize <= UInt64(indexRecordSize) ? clusterSize : 512
        let (blockByteOffset, overflow) = vcn.multipliedReportingOverflow(by: vcnUnit)
        guard !overflow else {
            throw NTFSError.corruptDirectoryIndex("Index block VCN \(vcn) is out of range")
        }

        // Read index record from non-resident runs
        let blockData = try RunReader.read(
            runs: runs,
            virtualOffset: blockByteOffset,
            length: indexRecordSize,
            clusterSize: clusterSize,
            device: blockDevice
        )

        var mutableData = blockData
        var reader = BinaryReader(data: mutableData)
        let magic = try reader.readASCIIString(byteCount: 4)
        guard magic == "INDX" else {
            throw NTFSError.corruptDirectoryIndex("Index block at VCN \(vcn) has no INDX signature")
        }

        let usaOffset = Int(try reader.readUInt16())
        let usaSize = Int(try reader.readUInt16())

        // Apply fixups to the INDX block
        try FixupApplier.applyFixup(
            data: &mutableData,
            updateSequenceOffset: usaOffset,
            updateSequenceSize: usaSize,
            bytesPerSector: Int(bootSector.bytesPerSector)
        )

        // The index node header of an INDX block is at offset 0x18.
        return try parseNode(
            data: mutableData,
            nodeHeaderOffset: 0x18,
            indexAlloc: indexAlloc,
            depth: depth,
            visitedVCNs: &visitedVCNs,
            visit: visit
        )
    }
}
