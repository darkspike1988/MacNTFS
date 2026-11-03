import Foundation
import NTFSCore

private struct OutputError: LocalizedError {
    var errorDescription: String? { "Writing to standard output failed" }
}

/// Read-only NTFS inspector. Opens images and devices read-only and never writes.
@main
struct MacNTFSCLI {
    /// 0 success, 1 error, 2 wrong usage, 3 the data uses an NTFS feature this tool does not read.
    private enum Exit {
        static let failure: Int32 = 1
        static let usage: Int32 = 2
        static let unsupported: Int32 = 3
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage(to: .standardError)
            exit(Exit.usage)
        }

        do {
            switch command {
            case "probe":
                guard args.count == 2 else { usageError("macntfs probe <image-or-device>") }
                try probe(path: args[1])

            case "ls":
                guard args.count == 2 || args.count == 3 else { usageError("macntfs ls <image-or-device> [path]") }
                try list(imagePath: args[1], directory: args.count == 3 ? args[2] : "/")

            case "cat":
                guard args.count == 3 else { usageError("macntfs cat <image-or-device> <file-path>") }
                try cat(imagePath: args[1], filePath: args[2])

            case "info":
                guard args.count == 3, let record = UInt64(args[2]) else {
                    usageError("macntfs info <image-or-device> <mft-record-number>")
                }
                try info(imagePath: args[1], recordNumber: record)

            case "help", "--help", "-h":
                printUsage(to: .standardOutput)

            default:
                printError("Unknown command '\(command)'")
                printUsage(to: .standardError)
                exit(Exit.usage)
            }
        } catch let error as NTFSError {
            printError(error.localizedDescription)
            if case .unsupported = error { exit(Exit.unsupported) }
            exit(Exit.failure)
        } catch {
            printError(error.localizedDescription)
            exit(Exit.failure)
        }
    }

    // MARK: - Commands

    private static func openVolume(_ path: String) throws -> NTFSVolume {
        // FileBlockDevice opens read-only unless asked otherwise. This tool never asks.
        try NTFSVolume(blockDevice: try FileBlockDevice(path: path))
    }

    private static func probe(path: String) throws {
        let vol = try openVolume(path)
        let boot = vol.bootSector

        print("Device:              \(path)")
        print("Volume name:         \(vol.volumeName)")
        print("Dirty flag:          \(vol.isDirty ? "set (not cleanly unmounted)" : "clear")")
        print("Bytes per sector:    \(boot.bytesPerSector)")
        print("Sectors per cluster: \(boot.sectorsPerCluster)")
        print("Cluster size:        \(boot.clusterSizeBytes) bytes")
        print("Total sectors:       \(boot.totalSectors)")
        print("Total size:          \(boot.totalSizeBytes) bytes")
        print("MFT start cluster:   \(boot.mftClusterNumber)")
        print("MFT mirror cluster:  \(boot.mftMirrorClusterNumber)")
        print("MFT record size:     \(boot.mftRecordSizeBytes) bytes")
        print("Index record size:   \(boot.indexRecordSizeBytes) bytes")
        print("Serial number:       0x\(String(boot.volumeSerialNumber, radix: 16).uppercased())")
        print("MFT runs:            \(vol.mftRecordRuns.count)")
    }

    private static func list(imagePath: String, directory: String) throws {
        let vol = try openVolume(imagePath)
        let items = try vol.listDirectory(at: directory)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")

        for item in items {
            let kind = item.isDirectory ? "d" : "-"
            let size = item.isDirectory ? "<DIR>" : String(item.fileSize)
            let padded = String(repeating: " ", count: max(0, 12 - size.count)) + size
            print("\(kind) \(padded)  \(formatter.string(from: item.modificationDate)) UTC  \(item.name)")
        }
    }

    private static func cat(imagePath: String, filePath: String) throws {
        let vol = try openVolume(imagePath)
        let (record, isDirectory) = try vol.lookup(path: filePath)

        // A directory link has the directory flag, but it is a link.
        if record.attribute(ofType: .reparsePoint) != nil {
            throw NTFSError.unsupported(.reparse)
        }
        guard !isDirectory else {
            throw NTFSError.isADirectory(filePath)
        }

        // Read in blocks, so large files do not have to fit in memory.
        let chunkSize = 4 * 1024 * 1024
        var offset: UInt64 = 0
        while true {
            let chunk = try vol.readData(record: record, offset: offset, length: chunkSize)
            if chunk.isEmpty { break }
            let written = chunk.withUnsafeBytes { fwrite($0.baseAddress, 1, chunk.count, stdout) }
            guard written == chunk.count else {
                throw OutputError()
            }
            offset += UInt64(chunk.count)
        }
        fflush(stdout)
    }

    private static func info(imagePath: String, recordNumber: UInt64) throws {
        let vol = try openVolume(imagePath)
        let record = try vol.readMFTRecord(number: recordNumber)

        print("MFT record \(recordNumber)")
        print("  In use:          \(record.isInUse)")
        print("  Directory:       \(record.isDirectory)")
        print("  Hard links:      \(record.header.hardLinkCount)")
        print("  Sequence number: \(record.header.sequenceNumber)")
        if let name = record.primaryFileName {
            print("  Name:            \(name.name)")
            print("  Size:            \(name.realSize) bytes")
            print("  Parent record:   \(name.parentDirectoryRecordNumber)")
        }

        print("  Attributes (\(record.attributes.count)):")
        for (index, attribute) in record.attributes.enumerated() {
            let name = attribute.name.map { " '\($0)'" } ?? ""
            switch attribute.payload {
            case .resident(let data):
                print("    [\(index)] \(attribute.type)\(name): resident, \(data.count) bytes")
            case .nonResident(let startVCN, let endVCN, let allocated, let real, let initialized, let runs):
                print("    [\(index)] \(attribute.type)\(name): non-resident, VCN \(startVCN)...\(endVCN), size \(real), initialized \(initialized), allocated \(allocated), \(runs.count) runs")
            }
        }
    }

    // MARK: - Output

    private static func printUsage(to stream: FileHandle) {
        let text = """
        macntfs: read-only NTFS inspector (experimental)

        Usage:
          macntfs probe <image-or-device>                  Show boot sector and volume information
          macntfs ls <image-or-device> [path]              List a directory
          macntfs cat <image-or-device> <file-path>        Write a file to standard output
          macntfs info <image-or-device> <mft-record>      Show one MFT record and its attributes

        Opens images and devices read-only. Compressed, encrypted and link data
        is refused with exit code 3 instead of returning wrong bytes. Devices need root and should
        not be mounted writable by another driver while you read them.

        Exit codes: 0 success, 1 error, 2 wrong usage, 3 unsupported NTFS feature.
        """
        stream.write(Data((text + "\n").utf8))
    }

    private static func usageError(_ usage: String) -> Never {
        printError("Usage: \(usage)")
        exit(Exit.usage)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("macntfs: \(message)\n".utf8))
    }
}
