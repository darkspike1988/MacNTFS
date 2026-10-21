import Foundation
import NTFSCore

@main
struct SwiftNTFSCLI {
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
                    print("Usage: swiftntfs probe <image-or-device>")
                    exit(1)
                }
                try await handleProbe(path: args[2])

            case "ls":
                guard args.count >= 3 else {
                    print("Usage: swiftntfs ls <image-or-device> [path]")
                    exit(1)
                }
                let targetPath = args.count >= 4 ? args[3] : "/"
                try await handleList(imagePath: args[2], dirPath: targetPath)

            case "cat":
                guard args.count >= 4 else {
                    print("Usage: swiftntfs cat <image-or-device> <file-path>")
                    exit(1)
                }
                try await handleCat(imagePath: args[2], filePath: args[3])

            case "info":
                guard args.count >= 4, let recordNum = UInt64(args[3]) else {
                    print("Usage: swiftntfs info <image-or-device> <mft-record-number>")
                    exit(1)
                }
                try await handleInfo(imagePath: args[2], recordNumber: recordNum)

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
        MacNTFS - High-Performance Pure Swift NTFS File System Engine
        Usage:
          macntfs probe <image-or-device>           Inspect VBR, BPB, volume metadata
          macntfs ls <image-or-device> [path]       List directory contents
          macntfs cat <image-or-device> <path>      Output file contents to stdout
          macntfs info <image-or-device> <record#>  Dump raw MFT record & attributes
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
}
