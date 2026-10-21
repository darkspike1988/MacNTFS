import Foundation

/// Information about a recoverable or deleted file discovered during forensic MFT carving.
public struct RecoverableFile: Identifiable, Sendable {
    public var id: UInt64 { recordNumber }
    public let recordNumber: UInt64
    public let fileName: String
    public let fileSize: UInt64
    public let modificationDate: Date
    public let isResident: Bool
    public let isDirectory: Bool
    public let confidence: RecoveryConfidence
    public let clusterCount: UInt64

    public enum RecoveryConfidence: String, Sendable {
        case excellent = "100% (Resident intakt)"
        case high = "Hoch (Clusterläufe vorhanden)"
        case moderate = "Mittel (Teilweise fragmentiert)"
        case uncertain = "Ungewiss"
    }

    public init(
        recordNumber: UInt64,
        fileName: String,
        fileSize: UInt64,
        modificationDate: Date,
        isResident: Bool,
        isDirectory: Bool,
        confidence: RecoveryConfidence,
        clusterCount: UInt64
    ) {
        self.recordNumber = recordNumber
        self.fileName = fileName
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.isResident = isResident
        self.isDirectory = isDirectory
        self.confidence = confidence
        self.clusterCount = clusterCount
    }
}

/// Comparison result between Primary and Backup Volume Boot Records.
public struct BootSectorForensics: Sendable {
    public let primaryValid: Bool
    public let backupValid: Bool
    public let oemIDMatches: Bool
    public let serialMatches: Bool
    public let clusterSizeMatches: Bool
    public let mftClusterMatches: Bool
    public let byteIdentical: Bool
    public let primarySerial: UInt64
    public let backupSerial: UInt64
    public let primaryClusterSize: UInt32
    public let backupClusterSize: UInt32
}

/// Forensic sector read diagnostics result.
public struct SurfaceScanReport: Sendable {
    public let totalSectorsScanned: UInt64
    public let totalBytesScanned: UInt64
    public let badSectors: [UInt64]
    public var isDamaged: Bool { !badSectors.isEmpty }

    public init(totalSectorsScanned: UInt64, totalBytesScanned: UInt64, badSectors: [UInt64]) {
        self.totalSectorsScanned = totalSectorsScanned
        self.totalBytesScanned = totalBytesScanned
        self.badSectors = badSectors
    }
}

/// Engine providing deep forensic inspection, file carving/recovery, hex dumps, and sector diagnostics.
public enum NTFSForensicsEngine {

    /// Scans the entire MFT looking for deleted or orphaned files (MFT records where isInUse == false).
    /// Extracts file names, original sizes, and cluster runs for carving.
    public static func scanDeletedFiles(volume: NTFSVolume) throws -> [RecoverableFile] {
        let boot = volume.bootSector
        let clusterSize = UInt64(boot.clusterSizeBytes)
        let recordSize = UInt64(boot.mftRecordSizeBytes)
        let totalRecords = volume.mftRecordRuns.reduce(0) { $0 + $1.clusterCount } * (clusterSize / recordSize)

        var found: [RecoverableFile] = []

        // Scan from record 16 (user records) up to total allocated MFT capacity
        for recNum in 16..<totalRecords {
            let virtualOffset = recNum * recordSize
            guard let rawBytes = try? readFromRuns(
                runs: volume.mftRecordRuns,
                virtualOffset: virtualOffset,
                length: Int(recordSize),
                bootSector: boot,
                device: volume.blockDevice
            ) else {
                continue
            }

            guard rawBytes.count >= 48 else { continue }

            // Check if magic is "FILE"
            let magic = String(decoding: rawBytes.prefix(4), as: UTF8.self)
            guard magic == "FILE" else { continue }

            // Attempt to parse MFTRecord with fixup restoration
            guard let record = try? MFTRecord(
                recordNumber: recNum,
                rawData: rawBytes,
                bytesPerSector: Int(boot.bytesPerSector)
            ) else {
                continue
            }

            // A deleted file has isInUse == false (bit 0x0001 cleared)
            if !record.isInUse {
                if let fn = record.primaryFileName {
                    let isDir = record.isDirectory || fn.isDirectory
                    var isRes = false
                    var clusterCount: UInt64 = 0
                    var confidence: RecoverableFile.RecoveryConfidence = .uncertain

                    if let dataAttr = record.defaultDataAttribute {
                        switch dataAttr.payload {
                        case .resident(_):
                            isRes = true
                            confidence = .excellent
                            clusterCount = 0
                        case .nonResident(_, _, _, _, _, let runs):
                            isRes = false
                            clusterCount = runs.reduce(0) { $0 + $1.clusterCount }
                            confidence = runs.count > 4 ? .moderate : .high
                        }
                    } else if isDir {
                        confidence = .high
                    }

                    found.append(RecoverableFile(
                        recordNumber: recNum,
                        fileName: fn.name,
                        fileSize: fn.realSize,
                        modificationDate: fn.modificationTime,
                        isResident: isRes,
                        isDirectory: isDir,
                        confidence: confidence,
                        clusterCount: clusterCount
                    ))
                }
            }
        }

        return found
    }

    /// Recovers (carves) the payload data of a deleted file by its MFT record number.
    public static func recoverDeletedFile(volume: NTFSVolume, recordNumber: UInt64) throws -> (name: String, data: Data) {
        let boot = volume.bootSector
        let recordSize = UInt64(boot.mftRecordSizeBytes)
        let virtualOffset = recordNumber * recordSize

        guard let rawBytes = try readFromRuns(
            runs: volume.mftRecordRuns,
            virtualOffset: virtualOffset,
            length: Int(recordSize),
            bootSector: boot,
            device: volume.blockDevice
        ) else {
            throw NTFSError.outOfBounds(offset: virtualOffset, requested: Int(recordSize), available: 0)
        }

        let record = try MFTRecord(
            recordNumber: recordNumber,
            rawData: rawBytes,
            bytesPerSector: Int(boot.bytesPerSector)
        )

        let fileName = record.primaryFileName?.name ?? "recovered_file_\(recordNumber)"
        let data = try volume.readData(record: record)
        return (fileName, data)
    }

    /// Performs forensic comparison between Primary VBR (Sector 0) and Backup VBR (Last sector).
    public static func compareBootSectors(device: BlockDevice) throws -> BootSectorForensics {
        let primaryData = try device.read(offset: 0, count: 512)
        let primaryBoot = try? BootSector(data: primaryData)

        let sectorSize: UInt64 = primaryBoot != nil ? UInt64(primaryBoot!.bytesPerSector) : 512
        let backupOffset = device.size >= sectorSize ? device.size - sectorSize : 0
        let backupData = backupOffset > 0 ? (try? device.read(offset: backupOffset, count: Int(sectorSize))) : nil
        let backupBoot = backupData != nil ? (try? BootSector(data: backupData!)) : nil

        let pValid = primaryBoot != nil
        let bValid = backupBoot != nil
        let byteId = (backupData != nil) ? (primaryData == backupData!) : false

        let oemMatch = pValid && bValid && (primaryBoot!.oemID == backupBoot!.oemID)
        let serMatch = pValid && bValid && (primaryBoot!.volumeSerialNumber == backupBoot!.volumeSerialNumber)
        let clusMatch = pValid && bValid && (primaryBoot!.clusterSizeBytes == backupBoot!.clusterSizeBytes)
        let mftMatch = pValid && bValid && (primaryBoot!.mftClusterNumber == backupBoot!.mftClusterNumber)

        return BootSectorForensics(
            primaryValid: pValid,
            backupValid: bValid,
            oemIDMatches: oemMatch,
            serialMatches: serMatch,
            clusterSizeMatches: clusMatch,
            mftClusterMatches: mftMatch,
            byteIdentical: byteId,
            primarySerial: primaryBoot?.volumeSerialNumber ?? 0,
            backupSerial: backupBoot?.volumeSerialNumber ?? 0,
            primaryClusterSize: primaryBoot?.clusterSizeBytes ?? 0,
            backupClusterSize: backupBoot?.clusterSizeBytes ?? 0
        )
    }

    /// Performs a non-destructive read surface scan across the device to identify damaged / unreadable sectors.
    public static func surfaceScan(
        device: BlockDevice,
        chunkSize: Int = 64 * 1024,
        maxBytesToScan: UInt64? = nil
    ) throws -> SurfaceScanReport {
        let limit = min(device.size, maxBytesToScan ?? device.size)
        var offset: UInt64 = 0
        var badSectors: [UInt64] = []
        let sectorSize: UInt64 = 512

        while offset < limit {
            let toRead = min(UInt64(chunkSize), limit - offset)
            do {
                _ = try device.read(offset: offset, count: Int(toRead))
            } catch {
                // Pinpoint specific bad sector(s) within the failing chunk
                var subOffset = offset
                let subEnd = offset + toRead
                while subOffset < subEnd {
                    do {
                        _ = try device.read(offset: subOffset, count: Int(sectorSize))
                    } catch {
                        badSectors.append(subOffset / sectorSize)
                    }
                    subOffset += sectorSize
                }
            }
            offset += toRead
        }

        return SurfaceScanReport(
            totalSectorsScanned: limit / sectorSize,
            totalBytesScanned: limit,
            badSectors: badSectors
        )
    }

    /// Generates a standardized forensic hexadecimal dump with ASCII view for arbitrary disk offsets.
    public static func hexDump(data: Data, baseOffset: UInt64 = 0, maxBytes: Int = 512) -> String {
        let count = min(data.count, maxBytes)
        var lines: [String] = []

        for i in stride(from: 0, to: count, by: 16) {
            let chunkEnd = min(i + 16, count)
            let chunk = data.subdata(in: (data.startIndex + i)..<(data.startIndex + chunkEnd))

            let addrStr = String(format: "%08llX", baseOffset + UInt64(i))

            var hexParts1: [String] = []
            var hexParts2: [String] = []
            var asciiStr = ""

            for (byteIdx, byte) in chunk.enumerated() {
                let hexByte = String(format: "%02X", byte)
                if byteIdx < 8 {
                    hexParts1.append(hexByte)
                } else {
                    hexParts2.append(hexByte)
                }

                if byte >= 32 && byte <= 126 {
                    asciiStr.append(Character(UnicodeScalar(byte)))
                } else {
                    asciiStr.append(".")
                }
            }

            while hexParts1.count < 8 { hexParts1.append("  ") }
            while hexParts2.count < 8 { hexParts2.append("  ") }
            while asciiStr.count < 16 { asciiStr.append(" ") }

            let hex1 = hexParts1.joined(separator: " ")
            let hex2 = hexParts2.joined(separator: " ")

            lines.append("\(addrStr)  \(hex1)  \(hex2)  |\(asciiStr)|")
        }

        return lines.joined(separator: "\n")
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
