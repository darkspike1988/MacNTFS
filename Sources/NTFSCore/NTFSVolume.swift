import Foundation

public final class NTFSVolume: Sendable {
    public let blockDevice: BlockDevice
    public let bootSector: BootSector
    public let volumeName: String
    public let isDirty: Bool
    public let mftRecordRuns: [DataRun]
    private let directoryIndexReader: DirectoryIndexReader

    public init(blockDevice: BlockDevice) throws {
        self.blockDevice = blockDevice

        // 1. Read Boot Sector
        let bootData = try blockDevice.read(offset: 0, count: 512)
        let boot = try BootSector(data: bootData)
        self.bootSector = boot
        self.directoryIndexReader = DirectoryIndexReader(blockDevice: blockDevice, bootSector: boot)

        // 2. Read bootstrap MFT Record 0 ($MFT) directly from boot.mftByteOffset
        let mft0Raw = try blockDevice.read(offset: boot.mftByteOffset, count: Int(boot.mftRecordSizeBytes))
        let mft0 = try MFTRecord(recordNumber: 0, rawData: mft0Raw, bytesPerSector: Int(boot.bytesPerSector))

        // A fragmented $MFT can keep part of its run list in extension records. Those are not read,
        // so opening such a volume would show only the first part of the MFT.
        if mft0.attribute(ofType: .attributeList) != nil {
            throw NTFSError.unsupported(.attributeList)
        }

        // 3. Extract $MFT's own $DATA runlist
        guard let mftDataAttr = mft0.defaultDataAttribute,
              let runs = mftDataAttr.runs else {
            throw NTFSError.corruptRunlist("$MFT record 0 does not contain non-resident $DATA runs")
        }
        self.mftRecordRuns = runs

        // 4. Read $Volume (Record 3) to extract Volume Name and Flags
        var detectedName = "NTFS"
        var dirty = false
        if let volRecord = try? NTFSVolume.readRecord(
            recordNumber: 3,
            runs: runs,
            bootSector: boot,
            device: blockDevice
        ) {
            if let nameAttr = volRecord.attribute(ofType: .volumeName),
               let resData = nameAttr.residentData {
                var reader = BinaryReader(data: resData)
                let charCount = resData.count / 2
                if let str = try? reader.readUTF16LEString(characterCount: charCount), !str.isEmpty {
                    detectedName = str
                }
            }

            if let infoAttr = volRecord.attribute(ofType: .volumeInformation),
               let resData = infoAttr.residentData,
               resData.count >= 12 {
                // Byte 8 is Major Version, Byte 9 is Minor Version
                // Bytes 10-11 are Flags (UInt16 LE: 0x0001 = Dirty flag)
                let flags = UInt16(resData[resData.startIndex + 10]) | (UInt16(resData[resData.startIndex + 11]) << 8)
                dirty = (flags & 0x0001) != 0
            }
        }

        self.volumeName = detectedName
        self.isDirty = dirty
    }

    /// Reads any arbitrary MFT record by its record number.
    public func readMFTRecord(number: UInt64) throws -> MFTRecord {
        return try NTFSVolume.readRecord(
            recordNumber: number,
            runs: mftRecordRuns,
            bootSector: bootSector,
            device: blockDevice
        )
    }

    private static func readRecord(
        recordNumber: UInt64,
        runs: [DataRun],
        bootSector: BootSector,
        device: BlockDevice
    ) throws -> MFTRecord {
        let recordSize = UInt64(bootSector.mftRecordSizeBytes)
        let (virtualOffset, overflow) = recordNumber.multipliedReportingOverflow(by: recordSize)
        guard !overflow else {
            throw NTFSError.outOfBounds(offset: recordNumber, requested: Int(recordSize), available: 0)
        }

        let rawBytes = try RunReader.read(
            runs: runs,
            virtualOffset: virtualOffset,
            length: Int(recordSize),
            clusterSize: UInt64(bootSector.clusterSizeBytes),
            device: device
        )

        return try MFTRecord(
            recordNumber: recordNumber,
            rawData: rawBytes,
            bytesPerSector: Int(bootSector.bytesPerSector)
        )
    }

    /// Largest range `readData` returns in one call. Read bigger files in chunks with `offset` and `length`.
    public static let maxSingleReadBytes: UInt64 = 1 << 30

    /// Reads the payload data for the default $DATA stream of a given MFT record.
    /// Throws `NTFSError.unsupported` for data it cannot read correctly instead of returning wrong bytes.
    public func readData(record: MFTRecord, offset: UInt64 = 0, length: Int? = nil) throws -> Data {
        if let length, length < 0 {
            throw NTFSError.outOfBounds(offset: offset, requested: length, available: 0)
        }
        // The data may live in extension records that are not read, or be a link or a placeholder.
        if record.attribute(ofType: .attributeList) != nil {
            throw NTFSError.unsupported(.attributeList)
        }
        if record.attribute(ofType: .reparsePoint) != nil {
            throw NTFSError.unsupported(.reparse)
        }
        guard let dataAttr = record.defaultDataAttribute else {
            return Data()
        }
        if dataAttr.flags.contains(.compressed) {
            throw NTFSError.unsupported(.compression)
        }
        if dataAttr.flags.contains(.encrypted) {
            throw NTFSError.unsupported(.encryption)
        }

        switch dataAttr.payload {
        case .resident(let resData):
            let total = UInt64(resData.count)
            guard offset < total else { return Data() }
            let available = total - offset
            let toRead = length != nil ? min(UInt64(length!), available) : available
            let start = Int(offset)
            let end = start + Int(toRead)
            return resData.subdata(in: start..<end)

        case .nonResident(let startingVCN, _, _, let realSize, let initializedSize, let runs):
            guard startingVCN == 0 else {
                throw NTFSError.corruptRunlist("$DATA starts at VCN \(startingVCN), expected 0")
            }
            guard offset < realSize else { return Data() }
            let available = realSize - offset
            let wanted = length != nil ? min(UInt64(length!), available) : available
            guard wanted <= NTFSVolume.maxSingleReadBytes else {
                throw NTFSError.resourceLimit("Reading \(wanted) bytes at once. Read large files in chunks with offset and length.")
            }
            let count = Int(wanted)

            // Bytes at or after the initialized size read as zeros, whatever is stored on disk.
            let validEnd = min(initializedSize, realSize)
            let onDisk = offset < validEnd ? Int(min(wanted, validEnd - offset)) : 0
            var result = onDisk > 0
                ? try RunReader.read(
                    runs: runs,
                    virtualOffset: offset,
                    length: onDisk,
                    clusterSize: UInt64(bootSector.clusterSizeBytes),
                    device: blockDevice
                )
                : Data()
            if onDisk < count {
                result.append(Data(count: count - onDisk))
            }
            return result
        }
    }

    /// Lists directory contents for a given MFT record number (defaults to 5 for Root directory).
    public func listDirectory(recordNumber: UInt64 = 5) throws -> [DirectoryItem] {
        let record = try readMFTRecord(number: recordNumber)
        return try directoryIndexReader.readEntries(from: record)
    }

    /// Lists directory contents for a given path (e.g. "/" or "/Folder/Subfolder").
    public func listDirectory(at path: String) throws -> [DirectoryItem] {
        let (record, isDir) = try lookup(path: path)
        guard isDir else {
            throw NTFSError.notADirectory(path)
        }
        return try directoryIndexReader.readEntries(from: record)
    }

    /// Resolves a path to its corresponding MFT record.
    public func lookup(path: String) throws -> (record: MFTRecord, isDirectory: Bool) {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
        let rootRecordNumber: UInt64 = 5 // Root directory is record 5 in NTFS
        var currentRecord = try readMFTRecord(number: rootRecordNumber)

        if trimmed.isEmpty {
            return (currentRecord, true)
        }

        let components = trimmed.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            guard currentRecord.isDirectory else {
                throw NTFSError.notADirectory(components.prefix(index).joined(separator: "/"))
            }

            // Names match by exact UTF-16 first, then case-insensitively. Walking into a link or a
            // directory with an attribute list throws NTFSError.unsupported.
            guard let match = try directoryIndexReader.findEntry(named: component, in: currentRecord) else {
                throw NTFSError.pathNotFound(path)
            }

            currentRecord = try readMFTRecord(number: match.mftRecordNumber)
        }

        return (currentRecord, currentRecord.isDirectory)
    }

    /// Reads entire file content for a given path.
    public func readFile(at path: String) throws -> Data {
        let (record, isDir) = try lookup(path: path)
        // A directory link has the directory flag, but it is a link and not a directory to read.
        if record.attribute(ofType: .reparsePoint) != nil {
            throw NTFSError.unsupported(.reparse)
        }
        guard !isDir else {
            throw NTFSError.unsupportedFeature("Cannot read raw file data of directory '\(path)'")
        }
        return try readData(record: record)
    }

    /// Writes or imports a file into a given directory path on this NTFS volume.
    @discardableResult
    public func writeFile(fileName: String, data: Data, directoryPath: String = "/") throws -> UInt64 {
        let (dirRecord, isDir) = try lookup(path: directoryPath)
        guard isDir else {
            throw NTFSError.notADirectory(directoryPath)
        }
        return try NTFSVolumeWriter.writeFile(
            volume: self,
            directoryRecordNumber: dirRecord.recordNumber,
            fileName: fileName,
            data: data
        )
    }

    /// Performs an integrity check on this volume.
    public func verifyHealth() throws -> NTFSHealthReport {
        return try NTFSVolumeChecker.verify(device: blockDevice)
    }

    /// Automatically repairs recoverable file system issues (e.g. dirty flag, backup boot sector).
    @discardableResult
    public func repairVolume() throws -> [String] {
        return try NTFSVolumeChecker.repair(device: blockDevice)
    }

    /// Scans the volume forensically for deleted and recoverable files in the MFT.
    public func scanDeletedFiles() throws -> [RecoverableFile] {
        return try NTFSForensicsEngine.scanDeletedFiles(volume: self)
    }

    /// Recovers / carves the data of a deleted file by its MFT record number.
    public func recoverDeletedFile(recordNumber: UInt64) throws -> (name: String, data: Data) {
        return try NTFSForensicsEngine.recoverDeletedFile(volume: self, recordNumber: recordNumber)
    }
}
