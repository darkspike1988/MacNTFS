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

    public init(blockDevice: BlockDevice, bootSector: BootSector) {
        self.blockDevice = blockDevice
        self.bootSector = bootSector
    }

    /// Reads all directory entries from an MFT record representing a directory.
    public func readEntries(from record: MFTRecord) throws -> [DirectoryItem] {
        guard record.isDirectory else {
            throw NTFSError.notADirectory("Record \(record.recordNumber) is not a directory")
        }

        guard let indexRootAttr = record.attribute(ofType: .indexRoot, name: "$I30"),
              let indexRootData = indexRootAttr.residentData else {
            throw NTFSError.attributeNotFound(type: AttributeType.indexRoot.rawValue, name: "$I30")
        }

        let indexAllocAttr = record.attribute(ofType: .indexAllocation, name: "$I30")

        var items = [DirectoryItem]()
        var visitedVCNs = Set<UInt64>()

        // 1. Parse entries in $INDEX_ROOT
        try parseIndexRoot(data: indexRootData, indexAlloc: indexAllocAttr, items: &items, visitedVCNs: &visitedVCNs)

        // Pure DOS 8.3 entries are skipped while parsing. They always come with a Win32 entry for the same file.
        // Hard links keep one item per name.
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func parseIndexRoot(
        data: Data,
        indexAlloc: NTFSAttribute?,
        items: inout [DirectoryItem],
        visitedVCNs: inout Set<UInt64>
    ) throws {
        guard data.count >= 32 else {
            throw NTFSError.corruptDirectoryIndex("INDEX_ROOT data too short")
        }

        var reader = BinaryReader(data: data, offset: 16) // Skip to Node Header at 0x10
        let firstEntryOffset = Int(try reader.readUInt32())
        let totalEntriesSize = Int(try reader.readUInt32())

        var currentOffset = 16 + firstEntryOffset
        let limitOffset = 16 + totalEntriesSize

        while currentOffset < limitOffset && currentOffset + 16 <= data.count {
            let entry = try IndexEntryParser.parse(data: data, offset: currentOffset)

            if let fn = entry.fileName {
                // Ignore '.' self-references and pure DOS 8.3 names
                if fn.name != "." && fn.namespace != .dos {
                    items.append(DirectoryItem(
                        name: fn.name,
                        mftRecordNumber: entry.mftRecordNumber,
                        isDirectory: fn.isDirectory,
                        fileSize: fn.realSize,
                        modificationDate: fn.modificationTime,
                        creationDate: fn.creationTime
                    ))
                }
            }

            if let vcn = entry.subNodeVCN {
                guard let alloc = indexAlloc else {
                    throw NTFSError.corruptDirectoryIndex("Index entry points to sub-node \(vcn), but the directory has no $INDEX_ALLOCATION")
                }
                try parseIndexBlock(vcn: vcn, indexAlloc: alloc, depth: 1, items: &items, visitedVCNs: &visitedVCNs)
            }

            if entry.isLastEntry || entry.entryLength == 0 {
                break
            }
            currentOffset += Int(entry.entryLength)
        }
    }

    /// B-trees of real directories are a few levels deep. A deeper chain means a damaged or hostile index.
    private static let maxIndexDepth = 32

    private func parseIndexBlock(
        vcn: UInt64,
        indexAlloc: NTFSAttribute,
        depth: Int,
        items: inout [DirectoryItem],
        visitedVCNs: inout Set<UInt64>
    ) throws {
        guard !visitedVCNs.contains(vcn) else { return }
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

        // Index Node Header is at offset 0x18
        var nodeReader = BinaryReader(data: mutableData, offset: 0x18)
        let firstEntryOffset = Int(try nodeReader.readUInt32())
        let totalEntriesSize = Int(try nodeReader.readUInt32())

        var currentOffset = 0x18 + firstEntryOffset
        let limitOffset = 0x18 + totalEntriesSize

        while currentOffset < limitOffset && currentOffset + 16 <= mutableData.count {
            let entry = try IndexEntryParser.parse(data: mutableData, offset: currentOffset)

            if let fn = entry.fileName {
                if fn.name != "." && fn.namespace != .dos {
                    items.append(DirectoryItem(
                        name: fn.name,
                        mftRecordNumber: entry.mftRecordNumber,
                        isDirectory: fn.isDirectory,
                        fileSize: fn.realSize,
                        modificationDate: fn.modificationTime,
                        creationDate: fn.creationTime
                    ))
                }
            }

            if let subVCN = entry.subNodeVCN {
                try parseIndexBlock(vcn: subVCN, indexAlloc: indexAlloc, depth: depth + 1, items: &items, visitedVCNs: &visitedVCNs)
            }

            if entry.isLastEntry || entry.entryLength == 0 {
                break
            }
            currentOffset += Int(entry.entryLength)
        }
    }
}
