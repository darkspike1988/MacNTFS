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

        // If main is invalid but backup is valid -> restore main. Only when sector 0 is a
        // damaged NTFS boot sector rather than another file system or a partition table,
        // and the backup sits exactly where NTFS keeps it (one sector past the volume).
        if mainBoot == nil, let bData = backupVbrData, let backupBoot,
           backupBoot.totalSectors * UInt64(backupBoot.bytesPerSector) == backupOffset,
           try mayReplaceBootSector(mainVbrData, device: device) {
            try device.write(offset: 0, data: bData)
            actions.append("Haupt-Bootsektor erfolgreich aus Backup-Bootsektor wiederhergestellt.")
        }

        // If main is valid but backup is missing/corrupted -> restore backup
        if let mData = try? device.read(offset: 0, count: 512), mainBoot != nil, backupBoot == nil, backupOffset > 0 {
            try device.write(offset: backupOffset, data: mData)
            actions.append("Backup-Bootsektor erfolgreich am Partitionsende synchronisiert.")
        }

        // The volume must have a usable boot sector from here on.
        _ = try BootSector(data: device.read(offset: 0, count: 512))

        // 3. Clear the dirty flag only when the journal has nothing left to replay. The
        // record is written to $MFT and $MFTMirr together, with its update sequence intact.
        let volume = try NTFSVolume(blockDevice: device)
        if volume.isDirty {
            if case .unclean(let reason) = try volume.journalState() {
                actions.append("Dirty-Flag nicht gelöscht: \(reason). Bitte chkdsk unter Windows ausführen.")
            } else {
                try NTFSVolumeWriter.clearDirtyFlag(volume)
                actions.append("Dirty Flag in $Volume erfolgreich gelöscht (Volume als 'Sauber' markiert).")
            }
        }

        try device.flush()
        if actions.isEmpty {
            actions.append("Dateisystem-Integrität überprüft: Keine Reparaturen erforderlich.")
        }
        return actions
    }

    /// Sector 0 may be replaced only if it is not another file system's boot sector, a
    /// partition table, or an APFS/HFS+ volume.
    static func mayReplaceBootSector(_ sector: Data, device: BlockDevice) throws -> Bool {
        guard sector.count >= 512 else { return false }
        if sector.subdata(in: 3..<11) == Data("NTFS    ".utf8) { return true }
        if sector[510] == 0x55 && sector[511] == 0xAA { return false }
        if sector.subdata(in: 32..<36) == Data("NXSB".utf8) { return false }
        if device.size >= 1026 {
            let header = try device.read(offset: 1024, count: 2)
            if header == Data("H+".utf8) || header == Data("HX".utf8) { return false }
        }
        return sector.allSatisfy { $0 == 0 }
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
