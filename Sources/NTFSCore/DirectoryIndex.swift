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

        // Deduplicate: If both DOS (8.3) and Win32 names exist for the same MFT record, prefer the long/Win32 name
        var uniqueItems = [UInt64: DirectoryItem]()
        for item in items {
            if let existing = uniqueItems[item.mftRecordNumber] {
                // Keep the one that doesn't look like a short DOS name or is longer
                if item.name.count > existing.name.count {
                    uniqueItems[item.mftRecordNumber] = item
                }
            } else {
                uniqueItems[item.mftRecordNumber] = item
            }
        }

        return Array(uniqueItems.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
                // Ignore '.' self-references
                if fn.name != "." {
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

            if let vcn = entry.subNodeVCN, let alloc = indexAlloc {
                try parseIndexBlock(vcn: vcn, indexAlloc: alloc, items: &items, visitedVCNs: &visitedVCNs)
            }

            if entry.isLastEntry || entry.entryLength == 0 {
                break
            }
            currentOffset += Int(entry.entryLength)
        }
    }

    private func parseIndexBlock(
        vcn: UInt64,
        indexAlloc: NTFSAttribute,
        items: inout [DirectoryItem],
        visitedVCNs: inout Set<UInt64>
    ) throws {
        guard !visitedVCNs.contains(vcn) else { return }
        visitedVCNs.insert(vcn)

        guard let runs = indexAlloc.runs else { return }

        let indexRecordSize = Int(bootSector.indexRecordSizeBytes)
        let clusterSize = Int(bootSector.clusterSizeBytes)
        let blockByteOffset = vcn * UInt64(clusterSize)

        // Read index record from non-resident runs
        guard let blockData = try readFromRuns(runs: runs, offset: blockByteOffset, length: indexRecordSize) else {
            return
        }

        guard blockData.count >= indexRecordSize else { return }

        var mutableData = blockData
        var reader = BinaryReader(data: mutableData)
        let magic = try reader.readASCIIString(byteCount: 4)
        guard magic == "INDX" else { return }

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
                if fn.name != "." {
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
                try parseIndexBlock(vcn: subVCN, indexAlloc: indexAlloc, items: &items, visitedVCNs: &visitedVCNs)
            }

            if entry.isLastEntry || entry.entryLength == 0 {
                break
            }
            currentOffset += Int(entry.entryLength)
        }
    }

    private func readFromRuns(runs: [DataRun], offset: UInt64, length: Int) throws -> Data? {
        let clusterSize = UInt64(bootSector.clusterSizeBytes)
        var result = Data()
        var currentRunVCN: UInt64 = 0
        var bytesNeeded = length
        var targetOffset = offset

        for run in runs {
            let runByteCount = run.clusterCount * clusterSize
            let runStartByte = currentRunVCN * clusterSize
            let runEndByte = runStartByte + runByteCount

            if targetOffset >= runStartByte && targetOffset < runEndByte {
                let offsetWithinRun = targetOffset - runStartByte
                let availableInRun = runByteCount - offsetWithinRun
                let toRead = min(Int(availableInRun), bytesNeeded)

                if let lcn = run.startingLCN {
                    let diskOffset = (lcn * clusterSize) + offsetWithinRun
                    let chunk = try blockDevice.read(offset: diskOffset, count: toRead)
                    result.append(chunk)
                } else {
                    // Sparse
                    result.append(Data(repeating: 0, count: toRead))
                }

                bytesNeeded -= toRead
                targetOffset += UInt64(toRead)

                if bytesNeeded <= 0 {
                    break
                }
            }

            currentRunVCN += run.clusterCount
        }

        return result.count == length ? result : nil
    }
}
