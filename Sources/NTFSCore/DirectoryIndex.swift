import Foundation

public struct DirectoryItem: Identifiable, Hashable, Sendable {
    public var id: UInt64 { mftRecordNumber }
    public let name: String
    public let mftRecordNumber: UInt64
    /// Sequence number of the record when the entry was made. Zero if the volume does not record one.
    public let sequenceNumber: UInt16
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

public final class DirectoryIndexReader: @unchecked Sendable {
    private let blockDevice: BlockDevice
    private let bootSector: BootSector
    private let upCase: UpCaseTable?

    /// The names of one directory, to find an entry without scanning the index again.
    private struct NameTable {
        var exact = [[UInt16]: DirectoryItem]()
        var folded = [[UInt16]: DirectoryItem]()
    }

    /// A directory is identified by its record and by the state of the record when its index was read.
    private struct DirectoryKey: Hashable {
        let record: UInt64
        let sequenceNumber: UInt16
        let logFileSequenceNumber: UInt64
    }

    /// Name tables of the directories read last. A client that walks a tree by path looks up one
    /// directory again and again; the table makes each step a dictionary lookup. A directory with more
    /// entries than `maxTableEntries` is scanned for each lookup instead, to keep memory bounded.
    private var tables = [DirectoryKey: NameTable]()
    private var tableOrder = [DirectoryKey]()
    private let tablesLock = NSLock()
    private static let maxTables = 8
    private static let maxTableEntries = 100_000

    /// B-trees of real directories are a few levels deep. A deeper chain means a damaged or hostile index.
    private static let maxIndexDepth = 32

    public convenience init(blockDevice: BlockDevice, bootSector: BootSector) {
        self.init(blockDevice: blockDevice, bootSector: bootSector, upCase: nil)
    }

    init(blockDevice: BlockDevice, bootSector: BootSector, upCase: UpCaseTable?) {
        self.blockDevice = blockDevice
        self.bootSector = bootSector
        self.upCase = upCase
    }

    /// Reads all directory entries from an MFT record representing a directory.
    /// Pure DOS 8.3 entries are skipped, because they always come with a Win32 entry for the same file.
    /// Hard links keep one item per name.
    public func readEntries(from record: MFTRecord) throws -> [DirectoryItem] {
        var items = [DirectoryItem]()
        var failure: Error?
        try walk(record) { data, entry in
            do {
                if let item = try DirectoryIndexReader.makeItem(from: entry, in: data) { items.append(item) }
            } catch {
                failure = error
                return true
            }
            return false
        }
        if let failure { throw failure }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Finds one entry by name. An exact match on the UTF-16 name wins over a case-insensitive match.
    /// The exact pass compares name bytes without building strings, so it is cheap on large directories.
    public func findEntry(named name: String, in record: MFTRecord) throws -> DirectoryItem? {
        let units = Array(name.utf16)
        if let table = try nameTable(for: record) {
            if let item = table.exact[units] { return item }
            return table.folded[foldedUnits(units)]
        }
        return try scanForEntry(named: name, units: units, in: record)
    }

    private func foldedUnits(_ units: [UInt16]) -> [UInt16] {
        upCase?.fold(units) ?? NTFSName.approximateFold(String(decoding: units, as: UTF16.self))
    }

    /// The name table of a directory, built on first use. Nil if the directory is too large to keep.
    private func nameTable(for record: MFTRecord) throws -> NameTable? {
        let key = DirectoryKey(
            record: record.recordNumber,
            sequenceNumber: record.header.sequenceNumber,
            logFileSequenceNumber: record.header.logFileSequenceNumber
        )
        tablesLock.lock()
        if let table = tables[key] {
            tablesLock.unlock()
            return table
        }
        tablesLock.unlock()

        var table = NameTable()
        var entries = 0
        var failure: Error?
        var tooLarge = false
        try walk(record) { data, entry in
            do {
                guard let item = try DirectoryIndexReader.makeItem(from: entry, in: data) else { return false }
                entries += 1
                if entries > DirectoryIndexReader.maxTableEntries {
                    tooLarge = true
                    return true
                }
                let units = Array(item.name.utf16)
                // The first entry with a name wins, as it does in a scan.
                if table.exact[units] == nil { table.exact[units] = item }
                let folded = foldedUnits(units)
                if table.folded[folded] == nil { table.folded[folded] = item }
            } catch {
                failure = error
                return true
            }
            return false
        }
        if let failure { throw failure }
        if tooLarge { return nil }

        tablesLock.lock()
        defer { tablesLock.unlock() }
        if tables[key] == nil {
            tables[key] = table
            tableOrder.append(key)
            if tableOrder.count > DirectoryIndexReader.maxTables {
                tables[tableOrder.removeFirst()] = nil
            }
        }
        return table
    }

    /// Finds an entry by scanning the index: an exact pass without strings, then a pass ignoring case.
    private func scanForEntry(named name: String, units: [UInt16], in record: MFTRecord) throws -> DirectoryItem? {
        var failure: Error?
        var found: DirectoryItem?

        try walk(record) { data, entry in
            guard entry.namespace(in: data) != .dos, entry.nameEquals(units, in: data) else { return false }
            do {
                found = try DirectoryIndexReader.makeItem(from: entry, in: data)
            } catch {
                failure = error
            }
            return true
        }
        if let failure { throw failure }
        if let found { return found }

        // No exact match: take the first name that matches ignoring case.
        let foldedUnits = upCase?.fold(units)
        try walk(record) { data, entry in
            guard entry.namespace(in: data) != .dos, entry.nameLength(in: data) == units.count else { return false }
            do {
                if let upCase, let foldedUnits {
                    guard entry.nameEqualsIgnoringCase(foldedUnits, upCase: upCase, in: data) else { return false }
                    found = try DirectoryIndexReader.makeItem(from: entry, in: data)
                } else {
                    guard let item = try DirectoryIndexReader.makeItem(from: entry, in: data),
                          NTFSName.isCaseInsensitiveMatch(item.name, name) else { return false }
                    found = item
                }
            } catch {
                failure = error
            }
            return true
        }
        if let failure { throw failure }
        return found
    }

    /// Builds the item for an index entry. Returns nil for the "." entry and for pure DOS names.
    private static func makeItem(from entry: RawIndexEntry, in data: Data) throws -> DirectoryItem? {
        let fn = try entry.fileName(in: data)
        guard fn.name != ".", fn.namespace != .dos else { return nil }
        return DirectoryItem(
            name: fn.name,
            mftRecordNumber: entry.mftRecordNumber,
            sequenceNumber: entry.sequenceNumber,
            isDirectory: fn.isDirectory,
            fileSize: fn.realSize,
            modificationDate: fn.modificationTime,
            creationDate: fn.creationTime
        )
    }

    /// Visits every entry that carries a file name. `visit` returns true to stop early.
    private func walk(_ record: MFTRecord, visit: (Data, RawIndexEntry) -> Bool) throws {
        guard record.isDirectory else {
            throw NTFSError.notADirectory("Record \(record.recordNumber) is not a directory")
        }
        // The index may live in extension records that are not read, and a link target is not this directory.
        if record.hasUnresolvedAttributeList {
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
        visit: (Data, RawIndexEntry) -> Bool
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
            let entry = try IndexEntryParser.parseRaw(data: data, offset: currentOffset)

            if entry.hasFileName, visit(data, entry) { return true }

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
            currentOffset += entry.entryLength
        }
        return false
    }

    /// Returns true if `visit` asked to stop.
    private func parseIndexBlock(
        vcn: UInt64,
        indexAlloc: NTFSAttribute,
        depth: Int,
        visitedVCNs: inout Set<UInt64>,
        visit: (Data, RawIndexEntry) -> Bool
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
        guard usaSize == mutableData.count / FixupApplier.blockSize + 1 else {
            throw NTFSError.corruptDirectoryIndex("Index block at VCN \(vcn) has \(usaSize) update sequence entries")
        }

        // Apply fixups to the INDX block
        try FixupApplier.applyFixup(
            data: &mutableData,
            updateSequenceOffset: usaOffset,
            updateSequenceSize: usaSize
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
