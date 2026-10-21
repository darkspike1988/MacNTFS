import Foundation
import NTFSCore

@main
struct MacNTFSCLI {
    static func main() async {
        let args = ProcessInfo.processInfo.arguments

        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        let command = args[1]

        do {
            switch command {
            case "probe":
                guard args.count >= 3 else {
                    print("Usage: macntfs probe <image-or-device>")
                    exit(1)
                }
                try await handleProbe(path: args[2])

            case "ls":
                guard args.count >= 3 else {
                    print("Usage: macntfs ls <image-or-device> [path]")
                    exit(1)
                }
                let targetPath = args.count >= 4 ? args[3] : "/"
                try await handleList(imagePath: args[2], dirPath: targetPath)

            case "cat":
                guard args.count >= 4 else {
                    print("Usage: macntfs cat <image-or-device> <file-path>")
                    exit(1)
                }
                try await handleCat(imagePath: args[2], filePath: args[3])

            case "info":
                guard args.count >= 4, let recordNum = UInt64(args[3]) else {
                    print("Usage: macntfs info <image-or-device> <mft-record-number>")
                    exit(1)
                }
                try await handleInfo(imagePath: args[2], recordNumber: recordNum)

            case "format":
                guard args.count >= 3 else {
                    print("Usage: macntfs format <image-or-device> [volume-name] [cluster-size-bytes]")
                    exit(1)
                }
                let devPath = args[2]
                let volName = args.count >= 4 ? args[3] : "UNTITLED"
                let clusterSize = args.count >= 5 ? (UInt32(args[4]) ?? 4096) : 4096
                try await handleFormat(path: devPath, name: volName, clusterSize: clusterSize)

            case "create-image":
                guard args.count >= 4, let sizeMB = UInt64(args[3]) else {
                    print("Usage: macntfs create-image <output-path> <size-in-mb> [volume-name]")
                    exit(1)
                }
                let outPath = args[2]
                let volName = args.count >= 5 ? args[4] : "UNTITLED"
                try await handleCreateImage(path: outPath, sizeMB: sizeMB, name: volName)

            case "check":
                guard args.count >= 3 else {
                    print("Usage: macntfs check <image-or-device> [--repair]")
                    exit(1)
                }
                let shouldRepair = args.contains("--repair")
                try await handleCheck(path: args[2], repair: shouldRepair)

            case "write":
                guard args.count >= 4 else {
                    print("Usage: macntfs write <image-or-device> <local-file-path> [dest-file-name]")
                    exit(1)
                }
                let devPath = args[2]
                let localPath = args[3]
                let destName = args.count >= 5 ? args[4] : URL(fileURLWithPath: localPath).lastPathComponent
                try await handleWrite(devPath: devPath, localFilePath: localPath, destFileName: destName)

            case "--help", "-h", "help":
                printUsage()

            default:
                print("Unknown command: '\(command)'")
                printUsage()
                exit(1)
            }
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        MacNTFS - High-Performance Pure Swift NTFS File System Engine & CLI
        Copyright (c) 2026 Michael Katschko

        Usage:
          macntfs probe <image-or-device>                 Inspect VBR, BPB, and volume metadata
          macntfs ls <image-or-device> [path]             List directory contents
          macntfs cat <image-or-device> <file-path>       Output file contents to stdout
          macntfs info <image-or-device> <record#>        Dump raw MFT record & attributes
          macntfs format <image-or-device> [name] [clus]  Format partition/file to NTFS
          macntfs create-image <path> <sizeMB> [name]     Create and format a blank NTFS disk image
          macntfs check <image-or-device> [--repair]      Verify filesystem integrity & auto-repair
          macntfs write <image-or-device> <local-file>    Write/import a file into the NTFS volume
        """)
    }

    static func handleProbe(path: String) async throws {
        let device = try FileBlockDevice(path: path)
        let vol = try NTFSVolume(blockDevice: device)
        let boot = vol.bootSector

        print("=== NTFS Volume Information ===")
        print("Device Path:         \(path)")
        print("Volume Name:         \(vol.volumeName)")
        print("Dirty Flag:          \(vol.isDirty ? "YES (Unclean unmount)" : "Clean")")
        print("OEM ID:              \(boot.oemID)")
        print("Bytes Per Sector:    \(boot.bytesPerSector)")
        print("Sectors Per Cluster: \(boot.sectorsPerCluster)")
        print("Cluster Size:        \(boot.clusterSizeBytes) bytes (\(boot.clusterSizeBytes / 1024) KB)")
        print("Total Sectors:       \(boot.totalSectors)")
        print("Total Size:          \(ByteCountFormatter.string(fromByteCount: Int64(boot.totalSizeBytes), countStyle: .file)) (\(boot.totalSizeBytes) bytes)")
        print("MFT Start Cluster:   LCN \(boot.mftClusterNumber) (Byte offset: 0x\(String(boot.mftByteOffset, radix: 16)))")
        print("MFT Mirror Cluster:  LCN \(boot.mftMirrorClusterNumber)")
        print("MFT Record Size:     \(boot.mftRecordSizeBytes) bytes")
        print("Index Record Size:   \(boot.indexRecordSizeBytes) bytes")
        print("Serial Number:       0x\(String(boot.volumeSerialNumber, radix: 16).uppercased())")
        print("MFT Run Count:       \(vol.mftRecordRuns.count)")
        for (idx, run) in vol.mftRecordRuns.enumerated() {
            let lcnStr = run.startingLCN != nil ? "LCN \(run.startingLCN!)" : "Sparse"
            print("  Run #\(idx): \(run.clusterCount) clusters at \(lcnStr)")
        }
    }

    static func handleList(imagePath: String, dirPath: String) async throws {
        let device = try FileBlockDevice(path: imagePath)
        let vol = try NTFSVolume(blockDevice: device)

        let items = try vol.listDirectory(at: dirPath)
        print("Listing for '\(dirPath)' on volume '\(vol.volumeName)':")
        print("Mode   Size         Modified                 Name")
        print("---------------------------------------------------------")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for item in items {
            let typeIndicator = item.isDirectory ? "d----" : "----"
            let sizeStr = item.isDirectory ? "<DIR>     " : String(format: "%10d", item.fileSize)
            let dateStr = dateFormatter.string(from: item.modificationDate)
            print("\(typeIndicator) \(sizeStr)   \(dateStr)   \(item.name)")
        }
        print("---------------------------------------------------------")
        print("Total items: \(items.count)")
    }

    static func handleCat(imagePath: String, filePath: String) async throws {
        let device = try FileBlockDevice(path: imagePath)
        let vol = try NTFSVolume(blockDevice: device)

        let data = try vol.readFile(at: filePath)
        FileHandle.standardOutput.write(data)
    }

    static func handleInfo(imagePath: String, recordNumber: UInt64) async throws {
        let device = try FileBlockDevice(path: imagePath)
        let vol = try NTFSVolume(blockDevice: device)

        let record = try vol.readMFTRecord(number: recordNumber)
        print("=== MFT Record #\(recordNumber) ===")
        print("Magic:               \(record.header.magic)")
        print("In Use:              \(record.isInUse)")
        print("Is Directory:        \(record.isDirectory)")
        print("Hard Links:          \(record.header.hardLinkCount)")
        print("Sequence Number:     \(record.header.sequenceNumber)")
        print("LogFile LSN:         \(record.header.logFileSequenceNumber)")
        print("Record Number (hdr): \(record.header.recordNumber)")

        if let fn = record.primaryFileName {
            print("Primary Name:        \(fn.name)")
            print("File Size:           \(fn.realSize) bytes (Allocated: \(fn.allocatedSize))")
            print("Parent MFT Record:   \(fn.parentDirectoryRecordNumber)")
        }

        print("\nAttributes (\(record.attributes.count)):")
        for (idx, attr) in record.attributes.enumerated() {
            let nameStr = attr.name != nil ? " ('\(attr.name!)')" : ""
            let residentStr = attr.isNonResident ? "Non-Resident" : "Resident"
            print("  [\(idx)] \(attr.type)\(nameStr) - \(residentStr), RecordLength: \(attr.recordLength) bytes")
            if case .nonResident(let startVCN, let endVCN, let alloc, let real, _, let runs) = attr.payload {
                print("      VCN: \(startVCN)..\(endVCN), RealSize: \(real), AllocSize: \(alloc), Runs: \(runs.count)")
                for (rIdx, run) in runs.enumerated() {
                    let lcn = run.startingLCN != nil ? "LCN \(run.startingLCN!)" : "Sparse"
                    print("        Run [\(rIdx)]: \(run.clusterCount) clusters @ \(lcn)")
                }
            } else if case .resident(let data) = attr.payload {
                print("      Payload: \(data.count) bytes resident")
            }
        }
    }

    static func handleFormat(path: String, name: String, clusterSize: UInt32) async throws {
        print("Formatting '\(path)' to NTFS (Label: '\(name)', Cluster size: \(clusterSize) bytes)...")
        let device = try FileBlockDevice(path: path, writable: true)
        try NTFSFormatter.format(
            device: device,
            options: .init(volumeName: name, clusterSize: clusterSize)
        )
        print("Format complete! Successfully initialized NTFS filesystem.")
    }

    static func handleCreateImage(path: String, sizeMB: UInt64, name: String) async throws {
        let totalBytes = sizeMB * 1024 * 1024
        print("Creating \(sizeMB) MB NTFS disk image at '\(path)'...")

        // Create empty sparse or pre-allocated file
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: totalBytes)
        try handle.close()

        let device = try FileBlockDevice(path: path, writable: true)
        try NTFSFormatter.format(
            device: device,
            options: .init(volumeName: name, clusterSize: 4096)
        )
        print("Successfully created and formatted '\(path)' (\(sizeMB) MB NTFS).")
    }

    static func handleCheck(path: String, repair: Bool) async throws {
        print("Checking NTFS filesystem on '\(path)' (Mode: \(repair ? "Check & Repair" : "Read-Only Check"))...")
        let device = try FileBlockDevice(path: path, writable: repair)
        let report = try NTFSVolumeChecker.verify(device: device)

        print("\n=== NTFS Diagnostics Report ===")
        print("Status:              \(report.isHealthy ? "HEALTHY (Clean)" : "ATTENTION NEEDED")")
        print("Volume Name:         \(report.volumeName)")
        print("Cluster Size:        \(report.clusterSizeBytes) bytes")
        print("Boot Sector:         \(report.bootSectorValid ? "Valid" : "CORRUPT")")
        print("Backup Boot Sector:  \(report.backupBootSectorValid ? "Valid" : "CORRUPT / MISSING")")
        print("MFT Record 0:        \(report.mft0Valid ? "Valid" : "CORRUPT")")
        print("Dirty Flag:          \(report.isDirty ? "DIRTY (Unclean Unmount)" : "Clean")")

        if !report.issues.isEmpty {
            print("\nIssues Detected:")
            for issue in report.issues {
                print("  • \(issue)")
            }
        }

        if repair {
            if !report.repairsAvailable.isEmpty {
                print("\nExecuting Repairs...")
                let actions = try NTFSVolumeChecker.repair(device: device)
                for action in actions {
                    print("  ✓ \(action)")
                }
                print("\nRepair completed successfully!")
            } else {
                print("\nNo repairs required.")
            }
        } else if !report.repairsAvailable.isEmpty {
            print("\nAvailable Repairs (Run with --repair to apply):")
            for rep in report.repairsAvailable {
                print("  → \(rep)")
            }
        }
    }

    static func handleWrite(devPath: String, localFilePath: String, destFileName: String) async throws {
        let localURL = URL(fileURLWithPath: localFilePath)
        guard FileManager.default.fileExists(atPath: localFilePath) else {
            print("Error: Local file does not exist at '\(localFilePath)'")
            exit(1)
        }

        let fileData = try Data(contentsOf: localURL)
        print("Importing '\(localURL.lastPathComponent)' (\(ByteCountFormatter.string(fromByteCount: Int64(fileData.count), countStyle: .file))) into NTFS volume at '\(devPath)'...")

        let device = try FileBlockDevice(path: devPath, writable: true)
        let vol = try NTFSVolume(blockDevice: device)
        let recNum = try vol.writeFile(fileName: destFileName, data: fileData)

        print("Successfully wrote '\(destFileName)' (Allocated MFT Record #\(recNum)).")
    }
}
