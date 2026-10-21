import Foundation

/// Provides file writing, creation, and directory indexing capabilities for NTFS volumes.
public enum NTFSVolumeWriter {

    /// Sanitizes file names according to Windows NTFS rules.
    /// Replaces characters prohibited in NTFS (`:`, `*`, `?`, `"`, `<`, `>`, `|`, `/`, `\`) with safe alternatives.
    public static func sanitizeFileName(_ name: String) -> String {
        var clean = name
        let illegalCharacters: [Character] = [":", "*", "?", "\"", "<", ">", "|", "/", "\\"]
        for ch in illegalCharacters {
            clean = clean.replacingOccurrences(of: String(ch), with: "_")
        }
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return clean.isEmpty ? "unnamed_file" : clean
    }

    /// Writes a file into an NTFS directory on a writable block device.
    ///
    /// - Parameters:
    ///   - volume: The NTFS volume instance.
    ///   - directoryRecordNumber: Target directory MFT record number (default: 5 for root).
    ///   - fileName: The file name.
    ///   - data: Raw file contents.
    /// - Returns: The allocated MFT record number for the newly created file.
    @discardableResult
    public static func writeFile(
        volume: NTFSVolume,
        directoryRecordNumber: UInt64 = 5,
        fileName: String,
        data: Data
    ) throws -> UInt64 {
        let device = volume.blockDevice
        guard device.isWritable else {
            throw BlockDeviceError.readOnlyDevice
        }

        let boot = volume.bootSector
        let clusterSize = UInt64(boot.clusterSizeBytes)
        let sanitizedName = sanitizeFileName(fileName)

        // 1. Read Cluster $Bitmap (MFT Record 6)
        let mft6 = try volume.readMFTRecord(number: 6)
        var bitmapData = try volume.readData(record: mft6)
        var bitmapManager = BitmapManager(data: bitmapData)

        // 2. Determine Cluster Allocation (Resident vs Non-Resident)
        var allocatedRuns: [DataRun]? = nil
        let isResident = data.count <= 600

        if !isResident {
            let clustersNeeded = Int((UInt64(data.count) + clusterSize - 1) / clusterSize)
            let freeStart = try bitmapManager.allocateContiguous(count: clustersNeeded, startIndex: 40)
            bitmapData = bitmapManager.data

            // Write updated $Bitmap to its designated cluster
            guard let bitmapAttr = mft6.defaultDataAttribute,
                  let bitmapRuns = bitmapAttr.runs,
                  let bitmapFirstRun = bitmapRuns.first,
                  let bitmapStartLCN = bitmapFirstRun.startingLCN else {
                throw NTFSError.corruptRunlist("Unable to locate $Bitmap cluster offset")
            }
            let bitmapDiskOffset = bitmapStartLCN * clusterSize
            try device.write(offset: bitmapDiskOffset, data: bitmapData)

            // Write actual file payload to allocated clusters on disk
            let fileDiskOffset = UInt64(freeStart) * clusterSize
            try device.write(offset: fileDiskOffset, data: data)

            allocatedRuns = [
                DataRun(clusterCount: UInt64(clustersNeeded), startingLCN: UInt64(freeStart))
            ]
        }

        // 3. Find next available MFT Record slot (starting from 16 for user files)
        let totalMFTCapacity = volume.mftRecordRuns.reduce(0) { $0 + $1.clusterCount } * (clusterSize / UInt64(boot.mftRecordSizeBytes))
        var targetRecordNumber: UInt64 = 16
        while targetRecordNumber < totalMFTCapacity {
            let recordOffset = targetRecordNumber * UInt64(boot.mftRecordSizeBytes)
            if let existingRaw = try? readFromRuns(runs: volume.mftRecordRuns, virtualOffset: recordOffset, length: Int(boot.mftRecordSizeBytes), bootSector: boot, device: device),
               let existingRec = try? MFTRecord(recordNumber: targetRecordNumber, rawData: existingRaw, bytesPerSector: Int(boot.bytesPerSector)) {
                if !existingRec.isInUse {
                    break
                }
            } else {
                break
            }
            targetRecordNumber += 1
        }

        // 4. Construct the 1024-byte MFT Record
        let fileRecordData = try MFTRecordBuilder.buildFileRecord(
            recordNumber: targetRecordNumber,
            sequenceNumber: 1,
            parentDirectoryRecordNumber: directoryRecordNumber,
            fileName: sanitizedName,
            fileContent: data,
            dataRuns: allocatedRuns,
            clusterSize: clusterSize
        )

        // Write the MFT Record to disk at MFT offset
        let mftVirtualOffset = targetRecordNumber * UInt64(boot.mftRecordSizeBytes)
        if let firstRun = volume.mftRecordRuns.first, let startLCN = firstRun.startingLCN {
            let mftDiskOffset = (startLCN * clusterSize) + mftVirtualOffset
            try device.write(offset: mftDiskOffset, data: fileRecordData)
        } else {
            throw NTFSError.corruptRunlist("Unable to resolve MFT disk offset")
        }

        // 5. Insert directory entry into parent directory's $INDEX_ROOT
        try insertDirectoryEntry(
            volume: volume,
            parentRecordNumber: directoryRecordNumber,
            childRecordNumber: targetRecordNumber,
            childName: sanitizedName,
            fileSize: UInt64(data.count)
        )

        try device.flush()
        return targetRecordNumber
    }

    private static func insertDirectoryEntry(
        volume: NTFSVolume,
        parentRecordNumber: UInt64,
        childRecordNumber: UInt64,
        childName: String,
        fileSize: UInt64
    ) throws {
        let device = volume.blockDevice
        let boot = volume.bootSector
        let clusterSize = UInt64(boot.clusterSizeBytes)
        let recordSize = UInt64(boot.mftRecordSizeBytes)

        let parentVirtualOffset = parentRecordNumber * recordSize
        guard var parentRaw = try readFromRuns(
            runs: volume.mftRecordRuns,
            virtualOffset: parentVirtualOffset,
            length: Int(recordSize),
            bootSector: boot,
            device: device
        ) else {
            throw NTFSError.outOfBounds(offset: parentVirtualOffset, requested: Int(recordSize), available: 0)
        }

        // Restore USA fixup in parent raw data first so we can parse and modify attributes
        let usaOffset = Int(UInt16(parentRaw[4]) | (UInt16(parentRaw[5]) << 8))
        let usaSize = Int(UInt16(parentRaw[6]) | (UInt16(parentRaw[7]) << 8))
        try FixupApplier.applyFixup(
            data: &parentRaw,
            updateSequenceOffset: usaOffset,
            updateSequenceSize: usaSize,
            bytesPerSector: Int(boot.bytesPerSector)
        )

        // Find $INDEX_ROOT (0x90) in parent record
        var offset = Int(UInt16(parentRaw[0x14]) | (UInt16(parentRaw[0x15]) << 8)) // firstAttrOffset
        var indexRootAttrOffset = -1

        while offset + 16 <= parentRaw.count {
            let attrType = UInt32(parentRaw[offset]) | (UInt32(parentRaw[offset + 1]) << 8) | (UInt32(parentRaw[offset + 2]) << 16) | (UInt32(parentRaw[offset + 3]) << 24)
            if attrType == 0xFFFFFFFF { break }

            let recLen = Int(UInt32(parentRaw[offset + 4]) | (UInt32(parentRaw[offset + 5]) << 8) | (UInt32(parentRaw[offset + 6]) << 16) | (UInt32(parentRaw[offset + 7]) << 24))
            guard recLen > 0 && offset + recLen <= parentRaw.count else { break }

            if attrType == 0x90 { // $INDEX_ROOT
                indexRootAttrOffset = offset
                break
            }
            offset += recLen
        }

        guard indexRootAttrOffset >= 0 else {
            throw NTFSError.attributeNotFound(type: 0x90, name: "$INDEX_ROOT")
        }

        // Parse resident header of $INDEX_ROOT
        let valLenOffset = indexRootAttrOffset + 16
        let valOffOffset = indexRootAttrOffset + 20
        var valLen = Int(UInt32(parentRaw[valLenOffset]) | (UInt32(parentRaw[valLenOffset + 1]) << 8) | (UInt32(parentRaw[valLenOffset + 2]) << 16) | (UInt32(parentRaw[valLenOffset + 3]) << 24))
        let valOff = Int(UInt16(parentRaw[valOffOffset]) | (UInt16(parentRaw[valOffOffset + 1]) << 8))

        let valStart = indexRootAttrOffset + valOff
        let nodeHeaderStart = valStart + 16 // 16 bytes Index Header, then Index Node Header

        let totalEntriesOffset = nodeHeaderStart + 4
        let allocEntriesOffset = nodeHeaderStart + 8

        let currentTotalEntries = Int(UInt32(parentRaw[totalEntriesOffset]) | (UInt32(parentRaw[totalEntriesOffset + 1]) << 8) | (UInt32(parentRaw[totalEntriesOffset + 2]) << 16) | (UInt32(parentRaw[totalEntriesOffset + 3]) << 24))

        // Build new IndexEntry for the child
        let newEntryData = buildIndexEntry(
            childRecordNumber: childRecordNumber,
            parentRecordNumber: parentRecordNumber,
            name: childName,
            fileSize: fileSize
        )

        // End marker is always the last 16 bytes of entries
        let endMarkerStart = nodeHeaderStart + currentTotalEntries - 16
        guard endMarkerStart >= nodeHeaderStart && endMarkerStart + 16 <= parentRaw.count else {
            throw NTFSError.corruptDirectoryIndex("Invalid end marker position in $INDEX_ROOT")
        }

        // Insert entry right before end marker
        parentRaw.insert(contentsOf: newEntryData, at: endMarkerStart)

        // Update sizes
        let entryByteCount = newEntryData.count
        valLen += entryByteCount
        let newTotalEntries = currentTotalEntries + entryByteCount

        var newTotal32 = UInt32(newTotalEntries).littleEndian
        var newAlloc32 = UInt32(newTotalEntries).littleEndian
        var newValLen32 = UInt32(valLen).littleEndian

        withUnsafeBytes(of: &newTotal32) { parentRaw.replaceSubrange(totalEntriesOffset..<(totalEntriesOffset + 4), with: $0) }
        withUnsafeBytes(of: &newAlloc32) { parentRaw.replaceSubrange(allocEntriesOffset..<(allocEntriesOffset + 4), with: $0) }
        withUnsafeBytes(of: &newValLen32) { parentRaw.replaceSubrange(valLenOffset..<(valLenOffset + 4), with: $0) }

        // Update attribute record length (aligned to 8 bytes)
        let oldAttrRecLen = Int(UInt32(parentRaw[indexRootAttrOffset + 4]) | (UInt32(parentRaw[indexRootAttrOffset + 5]) << 8) | (UInt32(parentRaw[indexRootAttrOffset + 6]) << 16) | (UInt32(parentRaw[indexRootAttrOffset + 7]) << 24))
        let newAttrRecLen = (oldAttrRecLen + entryByteCount + 7) & ~7
        var newAttrRecLen32 = UInt32(newAttrRecLen).littleEndian
        withUnsafeBytes(of: &newAttrRecLen32) { parentRaw.replaceSubrange((indexRootAttrOffset + 4)..<(indexRootAttrOffset + 8), with: $0) }

        // Update record Used Size (offset 0x18)
        let oldUsedSize = Int(UInt32(parentRaw[0x18]) | (UInt32(parentRaw[0x19]) << 8) | (UInt32(parentRaw[0x1A]) << 16) | (UInt32(parentRaw[0x1B]) << 24))
        let newUsedSize = min(1024, oldUsedSize + entryByteCount)
        var newUsed32 = UInt32(newUsedSize).littleEndian
        withUnsafeBytes(of: &newUsed32) { parentRaw.replaceSubrange(0x18..<0x1C, with: $0) }

        // Ensure record fits in 1024 bytes
        if parentRaw.count > 1024 {
            parentRaw = parentRaw.prefix(1024)
        }

        // Re-apply USA fixup
        FixupApplier.prepareForWrite(
            data: &parentRaw,
            updateSequenceOffset: usaOffset,
            updateSequenceSize: usaSize,
            bytesPerSector: Int(boot.bytesPerSector)
        )

        // Write parent record back to disk
        if let firstRun = volume.mftRecordRuns.first, let startLCN = firstRun.startingLCN {
            let parentDiskOffset = (startLCN * clusterSize) + parentVirtualOffset
            try device.write(offset: parentDiskOffset, data: parentRaw)
        }
    }

    private static func buildIndexEntry(
        childRecordNumber: UInt64,
        parentRecordNumber: UInt64,
        name: String,
        fileSize: UInt64
    ) -> Data {
        // Build $FILE_NAME stream
        var fnStream = Data()
        var parentRef = (parentRecordNumber & 0x0000_FFFF_FFFF_FFFF) | (UInt64(1) << 48)
        var nowFT = FileTimeConverter.toFileTime(date: Date()).littleEndian
        var fSize = fileSize.littleEndian
        var flags: UInt32 = 0x20 // ARCHIVE

        withUnsafeBytes(of: &parentRef) { fnStream.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { fnStream.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { fnStream.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { fnStream.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { fnStream.append(contentsOf: $0) }
        withUnsafeBytes(of: &fSize) { fnStream.append(contentsOf: $0) }
        withUnsafeBytes(of: &fSize) { fnStream.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { fnStream.append(contentsOf: $0) }
        fnStream.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Reparse / EA

        let utf16Chars = Array(name.utf16)
        fnStream.append(UInt8(utf16Chars.count))
        fnStream.append(0x03) // Win32 & DOS namespace

        for char in utf16Chars {
            var le = char.littleEndian
            withUnsafeBytes(of: &le) { fnStream.append(contentsOf: $0) }
        }

        // Build Index Entry Header (16 bytes)
        let unalignedEntryLen = 16 + fnStream.count
        let alignedEntryLen = (unalignedEntryLen + 7) & ~7

        var entry = Data()
        var rawChildRef = (childRecordNumber & 0x0000_FFFF_FFFF_FFFF) | (UInt64(1) << 48)
        var entryLen16 = UInt16(alignedEntryLen).littleEndian
        var streamLen16 = UInt16(fnStream.count).littleEndian
        var entryFlags: UInt16 = 0x0000 // Normal entry (not last)
        var pad16: UInt16 = 0

        withUnsafeBytes(of: &rawChildRef) { entry.append(contentsOf: $0) }
        withUnsafeBytes(of: &entryLen16) { entry.append(contentsOf: $0) }
        withUnsafeBytes(of: &streamLen16) { entry.append(contentsOf: $0) }
        withUnsafeBytes(of: &entryFlags) { entry.append(contentsOf: $0) }
        withUnsafeBytes(of: &pad16) { entry.append(contentsOf: $0) }

        entry.append(fnStream)

        // Pad to 8-byte alignment
        let padCount = alignedEntryLen - unalignedEntryLen
        if padCount > 0 {
            entry.append(contentsOf: [UInt8](repeating: 0, count: padCount))
        }

        return entry
    }

    private static func readFromRuns(
        runs: [DataRun],
        virtualOffset: UInt64,
        length: Int,
        bootSector: BootSector,
        device: BlockDevice
    ) throws -> Data? {
        let clusterSize = UInt64(bootSector.clusterSizeBytes)
        var result = Data()
        var currentRunVCN: UInt64 = 0
        var bytesNeeded = length
        var targetOffset = virtualOffset

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
                    let chunk = try device.read(offset: diskOffset, count: toRead)
                    result.append(chunk)
                } else {
                    result.append(Data(repeating: 0, count: toRead))
                }

                bytesNeeded -= toRead
                targetOffset += UInt64(toRead)
                if bytesNeeded <= 0 { break }
            }
            currentRunVCN += run.clusterCount
        }

        return result.count == length ? result : nil
    }
}
