import Foundation

/// Provides formatting capabilities to initialize new NTFS file systems on disk partitions or image files.
public enum NTFSFormatter {

    public struct FormatOptions: Sendable {
        public let volumeName: String
        public let clusterSize: UInt32
        public let sectorSize: UInt16

        public init(volumeName: String = "UNTITLED", clusterSize: UInt32 = 4096, sectorSize: UInt16 = 512) {
            self.volumeName = volumeName.isEmpty ? "UNTITLED" : volumeName
            self.clusterSize = clusterSize
            self.sectorSize = sectorSize
        }
    }

    /// Formats a writable block device into a standard Windows NTFS file system.
    ///
    /// - Parameters:
    ///   - device: The block device to format.
    ///   - options: Volume name, cluster size, etc.
    /// - Throws: `NTFSError` or `BlockDeviceError`
    public static func format(device: BlockDevice, options: FormatOptions = FormatOptions()) throws {
        guard device.isWritable else {
            throw BlockDeviceError.readOnlyDevice
        }

        let minSize: UInt64 = 10 * 1024 * 1024 // 10 MB minimum
        guard device.size >= minSize else {
            throw NTFSError.unsupportedFeature("Device too small for NTFS: \(device.size) bytes (minimum is 10 MB)")
        }

        let sectorSize = UInt64(options.sectorSize)
        let clusterSize = UInt64(options.clusterSize)
        let sectorsPerCluster = UInt8(clusterSize / sectorSize)
        let totalSectors = device.size / sectorSize
        let totalClusters = device.size / clusterSize

        // Standard NTFS layout:
        // Cluster 0: VBR (Sectors 0..7)
        // Clusters 4..31: $MFT starting cluster (28 clusters = 112 MFT records)
        // Clusters 32..35: $Bitmap
        let mftCluster: UInt64 = 4
        let mftClusterCount: UInt64 = 28
        let bitmapCluster: UInt64 = 32
        let mftMirrorCluster: UInt64 = totalClusters / 2
        let serialNumber = UInt64.random(in: 1...UInt64.max)

        // 1. Build Sector 0: Volume Boot Record
        let vbrData = buildVBR(
            totalSectors: totalSectors,
            sectorsPerCluster: sectorsPerCluster,
            sectorSize: options.sectorSize,
            mftCluster: mftCluster,
            mftMirrorCluster: mftMirrorCluster,
            serialNumber: serialNumber
        )

        // 2. Prepare Cluster $Bitmap (Record 6)
        let bitmapByteCount = Int((totalClusters + 7) / 8)
        var clusterBitmapData = Data(repeating: 0x00, count: bitmapByteCount)

        // Mark clusters 0..39 (system clusters) and MFT mirror clusters as allocated
        var bitmapManager = BitmapManager(data: clusterBitmapData)
        let initialReservedClusters = min(40, Int(totalClusters))
        for c in 0..<initialReservedClusters {
            try bitmapManager.setAllocated(at: c, isAllocated: true)
        }
        for c in 0..<4 {
            let mirrorC = Int(mftMirrorCluster) + c
            if mirrorC < Int(totalClusters) {
                try bitmapManager.setAllocated(at: mirrorC, isAllocated: true)
            }
        }
        clusterBitmapData = bitmapManager.data

        // 3. Construct System MFT Records (Records 0 to 15, 1024 bytes each = 16 KB)
        var mftRecordsData = Data(repeating: 0, count: Int(mftClusterCount * clusterSize))
        var systemRecords = Data()

        // Record 0: $MFT
        let mft0 = try buildMFT0Record(mftCluster: mftCluster, mftClusterCount: mftClusterCount, clusterSize: clusterSize)
        systemRecords.append(mft0)

        // Record 1: $MFTMirr
        let mft1 = try buildMFTMirrRecord(mirrorCluster: mftMirrorCluster)
        systemRecords.append(mft1)

        // Record 2: $LogFile
        let mft2 = try buildEmptySystemRecord(recordNumber: 2, name: "$LogFile")
        systemRecords.append(mft2)

        // Record 3: $Volume (Volume Name & Flags)
        let mft3 = try buildVolumeRecord(name: options.volumeName)
        systemRecords.append(mft3)

        // Record 4: $AttrDef
        let mft4 = try buildEmptySystemRecord(recordNumber: 4, name: "$AttrDef")
        systemRecords.append(mft4)

        // Record 5: $Root (Root Directory with empty $INDEX_ROOT)
        let mft5 = try buildRootDirectoryRecord()
        systemRecords.append(mft5)

        // Record 6: $Bitmap (Cluster allocation bitmap)
        let mft6 = try buildBitmapRecord(bitmapCluster: bitmapCluster, bitmapDataSize: UInt64(clusterBitmapData.count))
        systemRecords.append(mft6)

        // Record 7: $Boot
        let mft7 = try buildEmptySystemRecord(recordNumber: 7, name: "$Boot")
        systemRecords.append(mft7)

        // Records 8..15: System records ($BadClus, $Secure, $UpCase, $Extend, Reserved)
        for r in 8...15 {
            let emptyRec = try buildEmptySystemRecord(recordNumber: UInt64(r), name: "$Reserved_\(r)")
            systemRecords.append(emptyRec)
        }

        mftRecordsData.replaceSubrange(0..<systemRecords.count, with: systemRecords)

        // 4. Write all structures to the block device!
        // A. Sector 0 (VBR)
        try device.write(offset: 0, data: vbrData)

        // B. $MFT at cluster 4
        let mftByteOffset = mftCluster * clusterSize
        try device.write(offset: mftByteOffset, data: mftRecordsData)

        // C. $MFTMirr at mirror cluster (mirrors first 4 records = 4096 bytes)
        let mirrorByteOffset = mftMirrorCluster * clusterSize
        let mirrorChunk = mftRecordsData.prefix(4096)
        try device.write(offset: mirrorByteOffset, data: mirrorChunk)

        // D. Cluster $Bitmap at cluster 32
        let bitmapByteOffset = bitmapCluster * clusterSize
        try device.write(offset: bitmapByteOffset, data: clusterBitmapData)

        // E. Backup VBR at the very last sector of the partition (standard NTFS)
        let backupVBROffset = (totalSectors - 1) * sectorSize
        try device.write(offset: backupVBROffset, data: vbrData)

        // Flush all buffers to physical disk
        try device.flush()
    }

    private static func buildVBR(
        totalSectors: UInt64,
        sectorsPerCluster: UInt8,
        sectorSize: UInt16,
        mftCluster: UInt64,
        mftMirrorCluster: UInt64,
        serialNumber: UInt64
    ) -> Data {
        var vbr = Data(repeating: 0, count: 512)

        // Jump instruction (3 bytes): EB 52 90
        vbr[0] = 0xEB
        vbr[1] = 0x52
        vbr[2] = 0x90

        // OEM ID: "NTFS    " (8 bytes)
        let oemBytes = Array("NTFS    ".utf8)
        vbr.replaceSubrange(3..<11, with: oemBytes)

        // Bytes per sector (0x0B)
        var sSize = sectorSize.littleEndian
        withUnsafeBytes(of: &sSize) { vbr.replaceSubrange(0x0B..<0x0D, with: $0) }

        // Sectors per cluster (0x0D)
        vbr[0x0D] = sectorsPerCluster

        // Total sectors (0x28)
        var tSectors = totalSectors.littleEndian
        withUnsafeBytes(of: &tSectors) { vbr.replaceSubrange(0x28..<0x30, with: $0) }

        // MFT starting cluster (0x30)
        var mftClus = mftCluster.littleEndian
        withUnsafeBytes(of: &mftClus) { vbr.replaceSubrange(0x30..<0x38, with: $0) }

        // MFT Mirror starting cluster (0x38)
        var mftMirrClus = mftMirrorCluster.littleEndian
        withUnsafeBytes(of: &mftMirrClus) { vbr.replaceSubrange(0x38..<0x40, with: $0) }

        // Clusters per MFT record (0x40): 0xF6 = -10 -> 2^10 = 1024 bytes
        vbr[0x40] = 0xF6

        // Clusters per Index record (0x44): 0xF6 = 1024 bytes
        vbr[0x44] = 0xF6

        // Serial number (0x48)
        var sNum = serialNumber.littleEndian
        withUnsafeBytes(of: &sNum) { vbr.replaceSubrange(0x48..<0x50, with: $0) }

        // Boot signature at 510..511: 0x55, 0xAA
        vbr[510] = 0x55
        vbr[511] = 0xAA

        return vbr
    }

    private static func buildMFT0Record(mftCluster: UInt64, mftClusterCount: UInt64, clusterSize: UInt64) throws -> Data {
        // Record 0 describes $MFT itself
        let mftRuns = [
            DataRun(clusterCount: mftClusterCount, startingLCN: mftCluster)
        ]
        let encodedRuns = DataRunEncoder.encode(runs: mftRuns)
        let totalBytes = mftClusterCount * clusterSize

        return try buildRecordWithNonResidentData(
            recordNumber: 0,
            name: "$MFT",
            runs: encodedRuns,
            realSize: totalBytes,
            allocatedSize: totalBytes
        )
    }

    private static func buildMFTMirrRecord(mirrorCluster: UInt64) throws -> Data {
        let mirrorRuns = [
            DataRun(clusterCount: 1, startingLCN: mirrorCluster)
        ]
        let encodedRuns = DataRunEncoder.encode(runs: mirrorRuns)

        return try buildRecordWithNonResidentData(
            recordNumber: 1,
            name: "$MFTMirr",
            runs: encodedRuns,
            realSize: 4096,
            allocatedSize: 4096
        )
    }

    private static func buildBitmapRecord(bitmapCluster: UInt64, bitmapDataSize: UInt64) throws -> Data {
        let bitmapRuns = [
            DataRun(clusterCount: UInt64((bitmapDataSize + 4095) / 4096), startingLCN: bitmapCluster)
        ]
        let encodedRuns = DataRunEncoder.encode(runs: bitmapRuns)

        return try buildRecordWithNonResidentData(
            recordNumber: 6,
            name: "$Bitmap",
            runs: encodedRuns,
            realSize: bitmapDataSize,
            allocatedSize: UInt64(((bitmapDataSize + 4095) / 4096) * 4096)
        )
    }

    private static func buildVolumeRecord(name: String) throws -> Data {
        // Build Record 3 ($Volume) with $VOLUME_NAME and $VOLUME_INFORMATION
        var record = Data(repeating: 0, count: 1024)
        var offset = 0x38

        // Header
        writeHeader(into: &record, recordNumber: 3, isDirectory: false)

        // $STANDARD_INFORMATION (0x10)
        let stdInfo = buildEmptyStdInfo()
        record.replaceSubrange(offset..<(offset + stdInfo.count), with: stdInfo)
        offset += stdInfo.count

        // $VOLUME_NAME (0x60)
        let utf16Name = Array(name.utf16)
        var nameBytes = Data()
        for char in utf16Name {
            var le = char.littleEndian
            withUnsafeBytes(of: &le) { nameBytes.append(contentsOf: $0) }
        }
        let volNameAttr = wrapResident(type: 0x60, value: nameBytes, attrID: 1)
        record.replaceSubrange(offset..<(offset + volNameAttr.count), with: volNameAttr)
        offset += volNameAttr.count

        // $VOLUME_INFORMATION (0x70) (OS version: 3.1, flags: 0 = Clean)
        let volInfoData = Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Reserved
            0x03, 0x01,                                     // NTFS 3.1 (Major 3, Minor 1)
            0x00, 0x00                                      // Flags: 0x0000 = Clean (No Dirty bit)
        ])
        let volInfoAttr = wrapResident(type: 0x70, value: volInfoData, attrID: 2)
        record.replaceSubrange(offset..<(offset + volInfoAttr.count), with: volInfoAttr)
        offset += volInfoAttr.count

        // End Marker
        record.replaceSubrange(offset..<(offset + 8), with: Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]))
        offset += 8

        finalizeRecord(record: &record, usedSize: offset)
        return record
    }

    private static func buildRootDirectoryRecord() throws -> Data {
        // Record 5: Root Directory ($Root)
        var record = Data(repeating: 0, count: 1024)
        var offset = 0x38

        writeHeader(into: &record, recordNumber: 5, isDirectory: true)

        let stdInfo = buildEmptyStdInfo()
        record.replaceSubrange(offset..<(offset + stdInfo.count), with: stdInfo)
        offset += stdInfo.count

        // $FILE_NAME for root
        let fnData = buildRootFileName()
        let fnAttr = wrapResident(type: 0x30, value: fnData, attrID: 1)
        record.replaceSubrange(offset..<(offset + fnAttr.count), with: fnAttr)
        offset += fnAttr.count

        // $INDEX_ROOT for $I30
        let indexRootData = buildEmptyIndexRoot()
        let indexAttr = wrapResidentWithName(type: 0x90, name: "$I30", value: indexRootData, attrID: 2)
        record.replaceSubrange(offset..<(offset + indexAttr.count), with: indexAttr)
        offset += indexAttr.count

        // End marker
        record.replaceSubrange(offset..<(offset + 8), with: Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]))
        offset += 8

        finalizeRecord(record: &record, usedSize: offset)
        return record
    }

    private static func buildEmptySystemRecord(recordNumber: UInt64, name: String) throws -> Data {
        return try MFTRecordBuilder.buildFileRecord(
            recordNumber: recordNumber,
            sequenceNumber: 1,
            parentDirectoryRecordNumber: 5,
            fileName: name,
            fileContent: Data()
        )
    }

    private static func buildRecordWithNonResidentData(
        recordNumber: UInt64,
        name: String,
        runs: Data,
        realSize: UInt64,
        allocatedSize: UInt64
    ) throws -> Data {
        var record = Data(repeating: 0, count: 1024)
        var offset = 0x38

        writeHeader(into: &record, recordNumber: recordNumber, isDirectory: false)

        let stdInfo = buildEmptyStdInfo()
        record.replaceSubrange(offset..<(offset + stdInfo.count), with: stdInfo)
        offset += stdInfo.count

        // Non-resident $DATA attribute
        let nonResidentHeaderSize = 64
        let unalignedTotal = nonResidentHeaderSize + runs.count
        let alignedTotal = (unalignedTotal + 7) & ~7

        var attr = Data()
        var rawType = UInt32(0x80).littleEndian
        var recLen = UInt32(alignedTotal).littleEndian
        let nonRes: UInt8 = 1
        let nameLen: UInt8 = 0
        var nameOff: UInt16 = 0
        var flags: UInt16 = 0
        var attrID: UInt16 = 1
        var startVCN: UInt64 = 0
        var endVCN = UInt64(allocatedSize / 4096 - 1).littleEndian
        var runOff = UInt16(nonResidentHeaderSize).littleEndian
        var compUnit: UInt16 = 0
        var pad32: UInt32 = 0
        var allocBytes = allocatedSize.littleEndian
        var realBytes = realSize.littleEndian
        var initBytes = realSize.littleEndian

        withUnsafeBytes(of: &rawType) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &recLen) { attr.append(contentsOf: $0) }
        attr.append(nonRes)
        attr.append(nameLen)
        withUnsafeBytes(of: &nameOff) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &attrID) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &startVCN) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &endVCN) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &runOff) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &compUnit) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &pad32) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &allocBytes) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &realBytes) { attr.append(contentsOf: $0) }
        withUnsafeBytes(of: &initBytes) { attr.append(contentsOf: $0) }

        attr.append(runs)
        let padding = alignedTotal - unalignedTotal
        if padding > 0 {
            attr.append(contentsOf: [UInt8](repeating: 0, count: padding))
        }

        record.replaceSubrange(offset..<(offset + attr.count), with: attr)
        offset += attr.count

        // End Marker
        record.replaceSubrange(offset..<(offset + 8), with: Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]))
        offset += 8

        finalizeRecord(record: &record, usedSize: offset)
        return record
    }

    private static func writeHeader(into record: inout Data, recordNumber: UInt64, isDirectory: Bool) {
        var header = Data()
        header.append(contentsOf: [0x46, 0x49, 0x4C, 0x45]) // "FILE"
        header.append(contentsOf: [0x30, 0x00]) // USA offset = 0x30
        header.append(contentsOf: [0x03, 0x00]) // USA size = 3
        header.append(contentsOf: [UInt8](repeating: 0, count: 8)) // LSN
        header.append(contentsOf: [0x01, 0x00]) // Sequence number = 1
        header.append(contentsOf: [0x01, 0x00]) // Hard link count = 1
        header.append(contentsOf: [0x38, 0x00]) // First attr offset = 0x38
        let flagVal: UInt16 = isDirectory ? 0x0003 : 0x0001
        header.append(contentsOf: withUnsafeBytes(of: flagVal.littleEndian) { Array($0) })
        header.append(contentsOf: [UInt8](repeating: 0, count: 16)) // sizes + base ref
        header.append(contentsOf: [0x05, 0x00]) // Next attr ID
        header.append(contentsOf: [0x00, 0x00]) // Reserved
        let rec32 = UInt32(recordNumber).littleEndian
        header.append(contentsOf: withUnsafeBytes(of: rec32) { Array($0) })
        record.replaceSubrange(0..<header.count, with: header)
    }

    private static func buildEmptyStdInfo() -> Data {
        var value = Data()
        var nowFT = FileTimeConverter.toFileTime(date: Date()).littleEndian
        var dos: UInt32 = 0x20
        withUnsafeBytes(of: &nowFT) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &dos) { value.append(contentsOf: $0) }
        value.append(contentsOf: [UInt8](repeating: 0, count: 16))
        return wrapResident(type: 0x10, value: value, attrID: 0)
    }

    private static func buildRootFileName() -> Data {
        var val = Data()
        var parentRef: UInt64 = 5 // Root is parent of itself
        var nowFT = FileTimeConverter.toFileTime(date: Date()).littleEndian
        var size: UInt64 = 0
        var flags: UInt32 = 0x10 // Directory flag
        withUnsafeBytes(of: &parentRef) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &nowFT) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { val.append(contentsOf: $0) }
        val.append(contentsOf: [0, 0, 0, 0]) // reparse
        val.append(0x01) // name length = 1
        val.append(0x03) // Win32 & DOS
        val.append(contentsOf: [0x2E, 0x00]) // "."
        return val
    }

    private static func buildEmptyIndexRoot() -> Data {
        var val = Data()
        var attrType = UInt32(0x30).littleEndian // $FILE_NAME
        var collation = UInt32(0x01).littleEndian // BINARY
        var bytesPerRec = UInt32(4096).littleEndian
        let clusPerRec: UInt8 = 1
        withUnsafeBytes(of: &attrType) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &collation) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &bytesPerRec) { val.append(contentsOf: $0) }
        val.append(clusPerRec)
        val.append(contentsOf: [0, 0, 0]) // padding

        // Index Node Header:
        var firstEntryOff = UInt32(16).littleEndian
        var totalSize = UInt32(32).littleEndian
        var allocSize = UInt32(32).littleEndian
        let flags: UInt8 = 0
        withUnsafeBytes(of: &firstEntryOff) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &totalSize) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &allocSize) { val.append(contentsOf: $0) }
        val.append(flags)
        val.append(contentsOf: [0, 0, 0])

        // End Entry (16 bytes):
        var dummyRef: UInt64 = 0
        var entryLen = UInt16(16).littleEndian
        var streamLen: UInt16 = 0
        var entryFlags = UInt16(0x0002).littleEndian
        withUnsafeBytes(of: &dummyRef) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &entryLen) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &streamLen) { val.append(contentsOf: $0) }
        withUnsafeBytes(of: &entryFlags) { val.append(contentsOf: $0) }
        val.append(contentsOf: [0, 0]) // padding

        return val
    }

    private static func wrapResident(type: UInt32, value: Data, attrID: UInt16) -> Data {
        wrapResidentWithName(type: type, name: nil, value: value, attrID: attrID)
    }

    private static func wrapResidentWithName(type: UInt32, name: String?, value: Data, attrID: UInt16) -> Data {
        let nameBytes = name != nil ? Array(name!.utf16) : []
        let nameLength = nameBytes.count
        let headerSize = 24 + (nameLength * 2)
        let alignedHeader = (headerSize + 7) & ~7
        let unalignedTotal = alignedHeader + value.count
        let alignedTotal = (unalignedTotal + 7) & ~7

        var res = Data()
        var rawT = type.littleEndian
        var recLen = UInt32(alignedTotal).littleEndian
        let nonRes: UInt8 = 0
        let nLen = UInt8(nameLength)
        var nOff = (nameLength > 0 ? UInt16(24) : UInt16(0)).littleEndian
        var flags: UInt16 = 0
        var aID = attrID.littleEndian
        var vLen = UInt32(value.count).littleEndian
        var vOff = UInt16(alignedHeader).littleEndian
        var idx: UInt8 = 0
        var pad: UInt8 = 0

        withUnsafeBytes(of: &rawT) { res.append(contentsOf: $0) }
        withUnsafeBytes(of: &recLen) { res.append(contentsOf: $0) }
        res.append(nonRes)
        res.append(nLen)
        withUnsafeBytes(of: &nOff) { res.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { res.append(contentsOf: $0) }
        withUnsafeBytes(of: &aID) { res.append(contentsOf: $0) }
        withUnsafeBytes(of: &vLen) { res.append(contentsOf: $0) }
        withUnsafeBytes(of: &vOff) { res.append(contentsOf: $0) }
        res.append(idx)
        res.append(pad)

        for char in nameBytes {
            var le = char.littleEndian
            withUnsafeBytes(of: &le) { res.append(contentsOf: $0) }
        }

        let headerPad = alignedHeader - headerSize
        if headerPad > 0 {
            res.append(contentsOf: [UInt8](repeating: 0, count: headerPad))
        }

        res.append(value)

        let totalPad = alignedTotal - unalignedTotal
        if totalPad > 0 {
            res.append(contentsOf: [UInt8](repeating: 0, count: totalPad))
        }

        return res
    }

    private static func finalizeRecord(record: inout Data, usedSize: Int) {
        var uSize = UInt32(usedSize).littleEndian
        var aSize = UInt32(1024).littleEndian
        withUnsafeBytes(of: &uSize) { record.replaceSubrange(0x18..<0x1C, with: $0) }
        withUnsafeBytes(of: &aSize) { record.replaceSubrange(0x1C..<0x20, with: $0) }

        let usn: UInt16 = 0x4242
        let sec0Byte0 = record[510]
        let sec0Byte1 = record[511]
        let sec1Byte0 = record[1022]
        let sec1Byte1 = record[1023]

        record[0x30] = UInt8(usn & 0xFF)
        record[0x31] = UInt8((usn >> 8) & 0xFF)
        record[0x32] = sec0Byte0
        record[0x33] = sec0Byte1
        record[0x34] = sec1Byte0
        record[0x35] = sec1Byte1

        record[510] = UInt8(usn & 0xFF)
        record[511] = UInt8((usn >> 8) & 0xFF)
        record[1022] = UInt8(usn & 0xFF)
        record[1023] = UInt8((usn >> 8) & 0xFF)
    }
}
