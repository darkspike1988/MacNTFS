import Foundation
import Darwin
import NTFSCore

/// Delegates raw operations only after checking that the device is unmounted.
public enum PrivilegedDiskBridge {
    public static var helperBinaryPath: String {
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "macntfs"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("macntfs"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/macntfs"),
            URL(fileURLWithPath: "/opt/homebrew/bin/macntfs"),
            URL(fileURLWithPath: "/usr/local/bin/macntfs")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path ?? candidates[0].path
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MacNTFS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Drain output before waiting, so a full child output pipe cannot deadlock.
    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw failure(message.isEmpty ? "\(executable) wurde mit Status \(process.terminationStatus) beendet." : message)
        }
        return output
    }

    private static func canonicalDevice(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix("/dev/rdisk") ? resolved.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk") : resolved
    }

    /// Check live mounts even if discovery supplied no mount point.
    private static func activeMountPoint(devicePath: String) throws -> String? {
        let device = canonicalDevice(devicePath)
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else {
            throw failure("Der aktuelle Mount-Status konnte nicht sicher ermittelt werden.")
        }
        for index in 0..<Int(count) {
            var entry = entries[index]
            let source = withUnsafePointer(to: &entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
            }
            if canonicalDevice(source) == device {
                return withUnsafePointer(to: &entry.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
                }
            }
        }
        if device.hasPrefix("/dev/") {
            let data = try run("/usr/sbin/diskutil", ["info", "-plist", device])
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let mounted = info["Mounted"] as? Bool else {
                throw failure("Der Mount-Status ist unbekannt; direktes Schreiben wurde abgebrochen.")
            }
            if mounted {
                guard let mount = info["MountPoint"] as? String, !mount.isEmpty else {
                    throw failure("Das Gerät ist eingebunden, aber sein Mount-Pfad ist unbekannt.")
                }
                return mount
            }
        }
        return nil
    }

    public static func format(devicePath: String, volumeName: String, clusterSize: UInt32) throws {
        let bsdDisk = canonicalDevice(devicePath)
        let rawDevice = bsdDisk.hasPrefix("/dev/disk") ? bsdDisk.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk") : bsdDisk
        _ = try run("/usr/sbin/diskutil", ["unmountDisk", bsdDisk])
        guard try activeMountPoint(devicePath: bsdDisk) == nil else {
            throw failure("Das Gerät ist noch eingebunden; Formatieren wurde abgebrochen.")
        }
        _ = try run("/usr/bin/sudo", ["-n", helperBinaryPath, "format", rawDevice, volumeName, String(clusterSize)])
        _ = try run("/usr/sbin/diskutil", ["mount", bsdDisk])
    }

    /// Import into the selected directory, using the mounted filesystem's driver when present.
    public static func writeFile(devicePath: String, fileURL: URL, mountPoint: String? = nil, directoryPath: String = "/") throws {
        let components = directoryPath.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains(".") else {
            throw failure("Ungültiger Zielordner.")
        }
        let destinationPath = "/" + components.joined(separator: "/")
        let detectedMount = try activeMountPoint(devicePath: devicePath)
        if let mount = detectedMount ?? mountPoint {
            let root = URL(fileURLWithPath: mount).resolvingSymlinksInPath().standardizedFileURL
            let directory = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
                .resolvingSymlinksInPath().standardizedFileURL
            guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else {
                throw failure("Der Zielordner liegt außerhalb des eingebundenen Volumes.")
            }
            let destination = directory.appendingPathComponent(fileURL.lastPathComponent)
            // Refuse overwrite. Propagate permissions/read-only/collision failures without raw fallback.
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return
        }

        // Only opening failure may request privileges; parsing/writing failures must propagate.
        let device: FileBlockDevice
        do {
            device = try FileBlockDevice(path: devicePath, writable: true)
        } catch {
            guard try activeMountPoint(devicePath: devicePath) == nil else {
                throw failure("Das Gerät wurde inzwischen eingebunden; direkter Import wurde abgebrochen.")
            }
            _ = try run("/usr/bin/sudo", ["-n", helperBinaryPath, "write", devicePath, fileURL.path, fileURL.lastPathComponent, destinationPath])
            return
        }
        let volume = try NTFSVolume(blockDevice: device)
        let data = try Data(contentsOf: fileURL)
        guard try activeMountPoint(devicePath: devicePath) == nil else {
            throw failure("Das Gerät wurde inzwischen eingebunden; direktes Schreiben wurde abgebrochen.")
        }
        try volume.writeFile(fileName: fileURL.lastPathComponent, data: data, directoryPath: destinationPath)
    }
}
