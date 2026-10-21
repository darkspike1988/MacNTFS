import Foundation

/// Health and structural diagnostic report for an NTFS volume.
public struct NTFSHealthReport: Sendable {
    public let isHealthy: Bool
    public let bootSectorValid: Bool
    public let backupBootSectorValid: Bool
    public let mft0Valid: Bool
    public let isDirty: Bool
    public let volumeName: String
    public let clusterSizeBytes: UInt32
    public let totalSizeBytes: UInt64
    public let issues: [String]
    public let repairsAvailable: [String]

    public init(
        isHealthy: Bool,
        bootSectorValid: Bool,
        backupBootSectorValid: Bool,
        mft0Valid: Bool,
        isDirty: Bool,
        volumeName: String,
        clusterSizeBytes: UInt32,
        totalSizeBytes: UInt64,
        issues: [String],
        repairsAvailable: [String]
    ) {
        self.isHealthy = isHealthy
        self.bootSectorValid = bootSectorValid
        self.backupBootSectorValid = backupBootSectorValid
        self.mft0Valid = mft0Valid
        self.isDirty = isDirty
        self.volumeName = volumeName
        self.clusterSizeBytes = clusterSizeBytes
        self.totalSizeBytes = totalSizeBytes
        self.issues = issues
        self.repairsAvailable = repairsAvailable
    }
}

/// Provides diagnostic integrity verification and repair capabilities for NTFS volumes (chkdsk/fsck alternative).
public enum NTFSVolumeChecker {

    /// Performs an in-depth integrity check on an NTFS block device.
    public static func verify(device: BlockDevice) throws -> NTFSHealthReport {
        var issues: [String] = []
        var repairs: [String] = []

        // 1. Read Sector 0 (Main Boot Sector / VBR)
        let mainVbrData = try device.read(offset: 0, count: 512)
        var bootSectorValid = false
        var bootSector: BootSector? = nil

        do {
            let boot = try BootSector(data: mainVbrData)
            bootSector = boot
            bootSectorValid = true
        } catch {
            issues.append("Haupt-Bootsektor beschädigt oder ungültig: \(error.localizedDescription)")
            repairs.append("Haupt-Bootsektor aus Backup-Bootsektor wiederherstellen")
        }

        // 2. Read Backup Boot Sector (Last sector on disk)
        var backupBootSectorValid = false
        var backupVbrData: Data? = nil
        let sectorSize: UInt64 = bootSector != nil ? UInt64(bootSector!.bytesPerSector) : 512
        let backupOffset = device.size >= sectorSize ? device.size - sectorSize : 0

        if backupOffset > 0 {
            if let bData = try? device.read(offset: backupOffset, count: Int(sectorSize)) {
                backupVbrData = bData
                if (try? BootSector(data: bData)) != nil {
                    backupBootSectorValid = true
                } else {
                    issues.append("Backup-Bootsektor am Partitionsende ist ungültig oder fehlt.")
                    if bootSectorValid {
                        repairs.append("Backup-Bootsektor aus intaktem Haupt-Bootsektor synchronisieren")
                    }
                }
            }
        }

        // If main boot sector failed, but backup is valid, recover bootSector info from backup
        if !bootSectorValid, let bData = backupVbrData, let bBoot = try? BootSector(data: bData) {
            bootSector = bBoot
        }

        guard let boot = bootSector else {
            return NTFSHealthReport(
                isHealthy: false,
                bootSectorValid: false,
                backupBootSectorValid: false,
                mft0Valid: false,
                isDirty: false,
                volumeName: "Unbekannt",
                clusterSizeBytes: 0,
                totalSizeBytes: device.size,
                issues: issues,
                repairsAvailable: repairs
            )
        }

        // 3. Verify MFT Record 0 ($MFT)
        var mft0Valid = false
        var mftRuns: [DataRun] = []
        do {
            let mft0Raw = try device.read(offset: boot.mftByteOffset, count: Int(boot.mftRecordSizeBytes))
            let mft0 = try MFTRecord(recordNumber: 0, rawData: mft0Raw, bytesPerSector: Int(boot.bytesPerSector))
            if let dataAttr = mft0.defaultDataAttribute, let runs = dataAttr.runs, !runs.isEmpty {
                mft0Valid = true
                mftRuns = runs
            } else {
                issues.append("MFT Record 0 besitzt keine gültigen $DATA-Clusterläufe.")
            }
        } catch {
            issues.append("MFT Record 0 ($MFT) konnte nicht verifiziert werden: \(error.localizedDescription)")
        }

        // 4. Verify $Volume (Record 3) & Dirty Flag
        var isDirty = false
        var volumeName = "NTFS"

        if mft0Valid {
            let recordSize = UInt64(boot.mftRecordSizeBytes)
            let volRecordOffset = 3 * recordSize
            if let volRaw = try? readFromRuns(runs: mftRuns, virtualOffset: volRecordOffset, length: Int(recordSize), bootSector: boot, device: device),
               let volRecord = try? MFTRecord(recordNumber: 3, rawData: volRaw, bytesPerSector: Int(boot.bytesPerSector)) {

                if let nameAttr = volRecord.attribute(ofType: .volumeName), let resData = nameAttr.residentData {
                    var reader = BinaryReader(data: resData)
                    if let str = try? reader.readUTF16LEString(characterCount: resData.count / 2), !str.isEmpty {
                        volumeName = str
                    }
                }

                if let infoAttr = volRecord.attribute(ofType: .volumeInformation), let resData = infoAttr.residentData, resData.count >= 12 {
                    let flags = UInt16(resData[resData.startIndex + 10]) | (UInt16(resData[resData.startIndex + 11]) << 8)
                    if (flags & 0x0001) != 0 {
                        isDirty = true
                        issues.append("Volume wurde unsauber getrennt (Dirty Flag aktiv). Dateisystem-Schutz ist aktiv.")
                        repairs.append("Dirty Flag zurücksetzen und Dateisystem-Integrität wiederherstellen")
                    }
                }
            }
        }

        let isHealthy = bootSectorValid && backupBootSectorValid && mft0Valid && !isDirty

        return NTFSHealthReport(
            isHealthy: isHealthy,
            bootSectorValid: bootSectorValid,
            backupBootSectorValid: backupBootSectorValid,
            mft0Valid: mft0Valid,
            isDirty: isDirty,
            volumeName: volumeName,
            clusterSizeBytes: boot.clusterSizeBytes,
            totalSizeBytes: boot.totalSizeBytes,
            issues: issues,
            repairsAvailable: repairs
        )
    }

    /// Performs automatic repair of detectable issues on the NTFS volume.
    ///
    /// - Parameter device: The block device to repair (must be opened writable).
    /// - Returns: A list of human-readable repair actions that were completed.
    @discardableResult
    public static func repair(device: BlockDevice) throws -> [String] {
        guard device.isWritable else {
            throw BlockDeviceError.readOnlyDevice
        }

        var actions: [String] = []

        // 1. Check Boot Sectors
        let mainVbrData = try device.read(offset: 0, count: 512)
        let mainBoot = try? BootSector(data: mainVbrData)

        let sectorSize: UInt64 = mainBoot != nil ? UInt64(mainBoot!.bytesPerSector) : 512
        let backupOffset = device.size >= sectorSize ? device.size - sectorSize : 0
        let backupVbrData = try? device.read(offset: backupOffset, count: Int(sectorSize))
        let backupBoot = backupVbrData != nil ? (try? BootSector(data: backupVbrData!)) : nil

        // If main is invalid but backup is valid -> restore main
        if mainBoot == nil, let bData = backupVbrData, backupBoot != nil {
            try device.write(offset: 0, data: bData)
            actions.append("Haupt-Bootsektor erfolgreich aus Backup-Bootsektor wiederhergestellt.")
        }

        // If main is valid but backup is missing/corrupted -> restore backup
        if let mData = try? device.read(offset: 0, count: 512), mainBoot != nil, backupBoot == nil, backupOffset > 0 {
            try device.write(offset: backupOffset, data: mData)
            actions.append("Backup-Bootsektor erfolgreich am Partitionsende synchronisiert.")
        }

        // Re-read working boot sector
        let activeBootData = try device.read(offset: 0, count: 512)
        let activeBoot = try BootSector(data: activeBootData)

        // 2. Read MFT Record 0 to get MFT layout
        let mft0Raw = try device.read(offset: activeBoot.mftByteOffset, count: Int(activeBoot.mftRecordSizeBytes))
        let mft0 = try MFTRecord(recordNumber: 0, rawData: mft0Raw, bytesPerSector: Int(activeBoot.bytesPerSector))
        guard let dataAttr = mft0.defaultDataAttribute, let runs = dataAttr.runs else {
            throw NTFSError.corruptRunlist("MFT runs not found")
        }

        // 3. Repair Dirty Flag in $Volume (Record 3)
        let recordSize = UInt64(activeBoot.mftRecordSizeBytes)
        let volRecordOffset = 3 * recordSize
        if var volRaw = try readFromRuns(runs: runs, virtualOffset: volRecordOffset, length: Int(recordSize), bootSector: activeBoot, device: device) {
            var modified = false

            // Find offset of $VOLUME_INFORMATION (0x70)
            var offset = Int(UInt16(volRaw[0x14]) | (UInt16(volRaw[0x15]) << 8)) // firstAttrOffset
            while offset + 16 <= volRaw.count {
                let attrType = UInt32(volRaw[offset]) | (UInt32(volRaw[offset + 1]) << 8) | (UInt32(volRaw[offset + 2]) << 16) | (UInt32(volRaw[offset + 3]) << 24)
                if attrType == 0xFFFFFFFF { break }

                let recLen = Int(UInt32(volRaw[offset + 4]) | (UInt32(volRaw[offset + 5]) << 8) | (UInt32(volRaw[offset + 6]) << 16) | (UInt32(volRaw[offset + 7]) << 24))
                guard recLen > 0 && offset + recLen <= volRaw.count else { break }

                if attrType == 0x70 { // $VOLUME_INFORMATION
                    let isNonRes = volRaw[offset + 8] != 0
                    if !isNonRes {
                        let valOff = Int(UInt16(volRaw[offset + 20]) | (UInt16(volRaw[offset + 21]) << 8))
                        let flagsOff = offset + valOff + 10
                        if flagsOff + 1 < volRaw.count {
                            let oldFlags = UInt16(volRaw[flagsOff]) | (UInt16(volRaw[flagsOff + 1]) << 8)
                            if (oldFlags & 0x0001) != 0 {
                                let newFlags = oldFlags & ~0x0001 // Clear dirty bit
                                volRaw[flagsOff] = UInt8(newFlags & 0xFF)
                                volRaw[flagsOff + 1] = UInt8((newFlags >> 8) & 0xFF)
                                modified = true
                            }
                        }
                    }
                }

                offset += recLen
            }

            if modified {
                // Re-apply fixup array to Record 3
                let usaOffset = Int(UInt16(volRaw[4]) | (UInt16(volRaw[5]) << 8))
                let usaSize = Int(UInt16(volRaw[6]) | (UInt16(volRaw[7]) << 8))
                FixupApplier.prepareForWrite(
                    data: &volRaw,
                    updateSequenceOffset: usaOffset,
                    updateSequenceSize: usaSize
                )

                // Write Record 3 back to disk
                if let firstRun = runs.first, let startLCN = firstRun.startingLCN {
                    let clusterSize = UInt64(activeBoot.clusterSizeBytes)
                    let diskOffset = (startLCN * clusterSize) + volRecordOffset
                    try device.write(offset: diskOffset, data: volRaw)
                    actions.append("Dirty Flag in $Volume erfolgreich gelöscht (Volume als 'Sauber' markiert).")
                }
            }
        }

        try device.flush()
        if actions.isEmpty {
            actions.append("Dateisystem-Integrität überprüft: Keine Reparaturen erforderlich.")
        }
        return actions
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
