import Foundation
import NTFSCore

/// Provides transparent privilege escalation and delegation to the MacNTFS background helper tool.
/// This allows the graphical MacNTFS app to perform low-level partition writes and formatting
/// seamlessly without requiring the user to run Terminal commands.
public enum PrivilegedDiskBridge {

    public static let helperBinaryPath = "/Users/michaelkatschko/.local/bin/macntfs"

    /// Formats a block device partition to NTFS with specified volume label and cluster size.
    public static func format(devicePath: String, volumeName: String, clusterSize: UInt32) throws {
        let cleanDev = devicePath
            .replacingOccurrences(of: "/dev/r", with: "")
            .replacingOccurrences(of: "/dev/", with: "")
        let rDevPath = "/dev/r" + cleanDev
        let bsdDisk = "/dev/" + cleanDev

        // 1. Unmount disk first via diskutil to release any macOS kernel locks
        let unmountProcess = Process()
        unmountProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        unmountProcess.arguments = ["unmountDisk", "force", bsdDisk]
        try? unmountProcess.run()
        unmountProcess.waitUntilExit()

        // 2. Format with privileged helper
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [helperBinaryPath, "format", rDevPath, volumeName, String(clusterSize)]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Fehler beim Formatieren"
            throw NSError(
                domain: "MacNTFS",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errString]
            )
        }
    }

    /// Writes/imports a file into the root of an NTFS block device using either direct I/O or the helper.
    public static func writeFile(devicePath: String, fileURL: URL) throws {
        // 1. Direct in-process if device is openable writable
        if let dev = try? FileBlockDevice(path: devicePath, writable: true),
           let vol = try? NTFSVolume(blockDevice: dev),
           let data = try? Data(contentsOf: fileURL) {
            try vol.writeFile(fileName: fileURL.lastPathComponent, data: data, directoryPath: "/")
            return
        }

        // 2. Fallback to privileged helper
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [helperBinaryPath, "write", devicePath, fileURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Fehler beim Schreiben"
            throw NSError(
                domain: "MacNTFS",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errString]
            )
        }
    }
}
