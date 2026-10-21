import Foundation
import Combine
import Cocoa
import DiskArbitration
import UserNotifications
import IOKit
import NTFSCore

public struct DiscoveredDrive: Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var devicePath: String
    public var bsdName: String
    public var isDiskImage: Bool
    public var mountPoint: String?
    public var totalCapacity: UInt64
    public var freeSpace: UInt64
    public var isNTFS: Bool
    public var fileSystemName: String
    public var modelName: String
    public var vendor: String
    public var busProtocol: String
    public var serialNumber: String
    public var isDirty: Bool
    public var clusterSize: UInt32
    public var isReadOnly: Bool
    public var isSSD: Bool
    public var isSystemDisk: Bool
    public var isInternal: Bool

    public var usedSpace: UInt64 {
        totalCapacity > freeSpace ? totalCapacity - freeSpace : 0
    }

    public var usagePercentage: Double {
        guard totalCapacity > 0 else { return 0.0 }
        return Double(usedSpace) / Double(totalCapacity)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: DiscoveredDrive, rhs: DiscoveredDrive) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
public final class DriveManager: ObservableObject {
    @Published public var drives: [DiscoveredDrive] = []
    @Published public var selectedDriveID: UUID?
    @Published public var isScanning: Bool = false
    @Published public var errorMessage: String?

    // Keep active NTFS volume instances
    private var volumeCache: [UUID: NTFSVolume] = [:]
    private var daSession: DASession?

    public init() {
        refreshDrives()
        setupDiskWatcher()
    }

    private func setupDiskWatcher() {
        // 1. Listen to macOS NSWorkspace volume mount / unmount notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            Task { @MainActor in
                self?.handleVolumeMounted(notification: notif)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDrives()
            }
        }

        // 2. Register Apple DiskArbitration session for live hardware plug-in / removal
        if let session = DASessionCreate(kCFAllocatorDefault) {
            self.daSession = session
            DASessionSetDispatchQueue(session, DispatchQueue.main)

            DARegisterDiskAppearedCallback(session, nil, { disk, context in
                guard let ctx = context else { return }
                let manager = Unmanaged<DriveManager>.fromOpaque(ctx).takeUnretainedValue()
                Task { @MainActor in
                    manager.refreshDrives()
                }
            }, Unmanaged.passUnretained(self).toOpaque())

            DARegisterDiskDisappearedCallback(session, nil, { disk, context in
                guard let ctx = context else { return }
                let manager = Unmanaged<DriveManager>.fromOpaque(ctx).takeUnretainedValue()
                Task { @MainActor in
                    manager.refreshDrives()
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func handleVolumeMounted(notification: Notification) {
        refreshDrives()

        if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
            // If an NTFS drive was just plugged in and mounted
            if let matching = self.drives.first(where: { $0.mountPoint == url.path && $0.isNTFS }) {
                self.selectedDriveID = matching.id
                sendNotification(
                    title: "NTFS-Laufwerk erkannt",
                    body: "'\(name)' ist einsatzbereit. Du kannst jetzt direkt Dateien per Drag & Drop schreiben."
                )
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    public func getNTFSVolume(for drive: DiscoveredDrive) -> NTFSVolume? {
        if let cached = volumeCache[drive.id] {
            return cached
        }
        guard drive.isNTFS else { return nil }
        do {
            let device = try FileBlockDevice(path: drive.devicePath, writable: true, allowReadOnlyFallback: true)
            let vol = try NTFSVolume(blockDevice: device)
            volumeCache[drive.id] = vol
            return vol
        } catch {
            return nil
        }
    }

    public func refreshDrives() {
        isScanning = true
        var found: [DiscoveredDrive] = []

        // 1. Scan mounted volumes in /Volumes
        let fileManager = FileManager.default
        let rootKeys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsReadOnlyKey
        ]

        if let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: rootKeys, options: [.skipHiddenVolumes]) {
            for url in urls {
                let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
                let total = UInt64((try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity) ?? 0)
                let available = UInt64((try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0)
                let isReadOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false

                // Check BSD name via statfs
                var stat = statfs()
                let pathStr = url.path
                var bsdPath = ""
                var rawFsType = ""
                if statfs(pathStr, &stat) == 0 {
                    let mntFrom = withUnsafeBytes(of: &stat.f_mntfromname) { rawPtr -> String in
                        guard let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                        return String(cString: ptr)
                    }
                    let fstype = withUnsafeBytes(of: &stat.f_fstypename) { rawPtr -> String in
                        guard let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                        return String(cString: ptr)
                    }
                    bsdPath = mntFrom
                    rawFsType = fstype.lowercased()
                }

                // Query Apple IOKit hardware registry for real model, vendor, bus protocol, and serial number
                let hwInfo = DiskHardwareProbe.query(bsdPath: bsdPath)

                // Probe with our native NTFSCore if device has an NTFS Boot Sector
                var isNtfsType = rawFsType.contains("ntfs") || bsdPath.contains("ntfs")
                var isClean = true
                var clusterSize: UInt32 = 4096
                var serialStr = hwInfo.serialNumber

                if !bsdPath.isEmpty {
                    if let rawDev = try? FileBlockDevice(path: bsdPath),
                       let ntfsVol = try? NTFSVolume(blockDevice: rawDev) {
                        isNtfsType = true
                        isClean = !ntfsVol.isDirty
                        clusterSize = ntfsVol.bootSector.clusterSizeBytes
                        let ntfsSerial = String(format: "%016llX", ntfsVol.bootSector.volumeSerialNumber)
                        if ntfsSerial != "0000000000000000" && (serialStr == "N/A" || serialStr.isEmpty) {
                            serialStr = ntfsSerial
                        }
                    }
                }

                // Map human-readable file system name
                let fsDisplayName: String
                if isNtfsType {
                    fsDisplayName = "Windows NT File System (NTFS)"
                } else {
                    switch rawFsType {
                    case "apfs":
                        fsDisplayName = "Apple File System (APFS)"
                    case "exfat":
                        fsDisplayName = "Extensible File Allocation Table (ExFAT)"
                    case "msdos":
                        fsDisplayName = "MS-DOS (FAT32)"
                    case "hfs":
                        fsDisplayName = "Mac OS Extended (HFS+)"
                    default:
                        fsDisplayName = rawFsType.isEmpty ? "Unbekannt" : rawFsType.uppercased()
                    }
                }

                let isVirtual = hwInfo.isVirtualDisk ||
                    url.path.contains("Simulator") ||
                    url.path.contains("Cryptex") ||
                    name.contains("Simulator") ||
                    name.contains("Cryptex") ||
                    hwInfo.busProtocol.contains("Disk Image") ||
                    hwInfo.model.contains("Disk Image")

                // Completely skip all virtual / digital disks
                if isVirtual {
                    continue
                }

                let isInternal = (try? url.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? (hwInfo.busProtocol.contains("Fabric") || bsdPath.contains("disk0"))
                let isSystem = url.path == "/" || url.path.starts(with: "/System") || name == "Macintosh HD" || name == "Data"

                let drive = DiscoveredDrive(
                    id: UUID(),
                    name: name,
                    devicePath: bsdPath.isEmpty ? url.path : bsdPath,
                    bsdName: bsdPath.replacingOccurrences(of: "/dev/", with: ""),
                    isDiskImage: isVirtual,
                    mountPoint: url.path,
                    totalCapacity: total,
                    freeSpace: available,
                    isNTFS: isNtfsType,
                    fileSystemName: fsDisplayName,
                    modelName: hwInfo.model,
                    vendor: hwInfo.vendor,
                    busProtocol: hwInfo.busProtocol,
                    serialNumber: serialStr,
                    isDirty: isNtfsType ? !isClean : false,
                    clusterSize: clusterSize,
                    isReadOnly: isReadOnly,
                    isSSD: hwInfo.isSSD,
                    isSystemDisk: isSystem,
                    isInternal: isInternal
                )
                found.append(drive)
            }
        }

        // 2. Discover physical block devices and partitions via IOKit (e.g. unmounted external NTFS drives)
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOMedia")
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    let bsdName = dict["BSD Name"] as? String ?? ""
                    let content = dict["Content"] as? String ?? ""
                    let size = dict["Size"] as? UInt64 ?? 0
                    let whole = dict["Whole"] as? Bool ?? false
                    let ejectable = dict["Ejectable"] as? Bool ?? false
                    let removable = dict["Removable"] as? Bool ?? false

                    let bsdPath = "/dev/" + bsdName
                    let rbsdPath = "/dev/r" + bsdName

                    let isAlreadyFound = found.contains(where: {
                        $0.bsdName == bsdName ||
                        $0.devicePath == bsdPath ||
                        $0.devicePath == rbsdPath
                    })

                    // Only process partition slices with reasonable size (> 10MB) not already in found
                    if !whole && size >= 10_000_000 && !isAlreadyFound && !bsdName.starts(with: "disk1s") && !bsdName.starts(with: "disk2s") {
                        let hwInfo = DiskHardwareProbe.query(bsdPath: bsdPath)
                        var isNtfs = content.lowercased().contains("ntfs") || content == "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
                        var volumeName = bsdName
                        var isClean = true
                        var clusterSize: UInt32 = 4096
                        var serialStr = hwInfo.serialNumber

                        if let rawDev = try? FileBlockDevice(path: rbsdPath, writable: false, allowReadOnlyFallback: true),
                           let ntfsVol = try? NTFSVolume(blockDevice: rawDev) {
                            isNtfs = true
                            isClean = !ntfsVol.isDirty
                            clusterSize = ntfsVol.bootSector.clusterSizeBytes
                            if !ntfsVol.volumeName.isEmpty {
                                volumeName = ntfsVol.volumeName
                            }
                            let ntfsSerial = String(format: "%016llX", ntfsVol.bootSector.volumeSerialNumber)
                            if ntfsSerial != "0000000000000000" && (serialStr == "N/A" || serialStr.isEmpty) {
                                serialStr = ntfsSerial
                            }
                        }

                        // Add if it's NTFS or an external removable drive
                        if isNtfs || ejectable || removable {
                            let drive = DiscoveredDrive(
                                id: UUID(),
                                name: volumeName,
                                devicePath: rbsdPath,
                                bsdName: bsdName,
                                isDiskImage: false,
                                mountPoint: nil,
                                totalCapacity: size,
                                freeSpace: isNtfs ? (size / 10) : 0,
                                isNTFS: isNtfs,
                                fileSystemName: isNtfs ? "Windows NT File System (NTFS)" : content,
                                modelName: hwInfo.model.isEmpty ? (dict["Media Name"] as? String ?? "USB Drive") : hwInfo.model,
                                vendor: hwInfo.vendor,
                                busProtocol: hwInfo.busProtocol,
                                serialNumber: serialStr,
                                isDirty: isNtfs ? !isClean : false,
                                clusterSize: clusterSize,
                                isReadOnly: false,
                                isSSD: hwInfo.isSSD,
                                isSystemDisk: false,
                                isInternal: !(ejectable || removable)
                            )
                            found.append(drive)
                        }
                    }
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        self.drives = found
        if selectedDriveID == nil || !found.contains(where: { $0.id == selectedDriveID }) {
            selectedDriveID = found.first(where: { $0.isNTFS })?.id ?? found.first?.id
        }
        self.isScanning = false
    }

    /// Mounts an unmounted NTFS drive via diskutil.
    public func mount(drive: DiscoveredDrive) {
        let bsdDisk = "/dev/" + drive.bsdName.replacingOccurrences(of: "rdisk", with: "disk")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["mount", bsdDisk]
        try? process.run()
        process.waitUntilExit()
        refreshDrives()
    }

    /// Safely unmounts/ejects a mounted drive via diskutil.
    public func unmount(drive: DiscoveredDrive) {
        let bsdDisk = "/dev/" + drive.bsdName.replacingOccurrences(of: "rdisk", with: "disk")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", bsdDisk]
        try? process.run()
        process.waitUntilExit()
        refreshDrives()
    }

    /// Loads a raw NTFS disk image (.img, .raw, .vhd) into the manager.
    public func loadDiskImage(at url: URL) {
        do {
            let device = try FileBlockDevice(path: url.path)
            let vol = try NTFSVolume(blockDevice: device)
            let boot = vol.bootSector

            let drive = DiscoveredDrive(
                id: UUID(),
                name: vol.volumeName.isEmpty ? url.deletingPathExtension().lastPathComponent : vol.volumeName,
                devicePath: url.path,
                bsdName: url.lastPathComponent,
                isDiskImage: true,
                mountPoint: nil,
                totalCapacity: boot.totalSizeBytes,
                freeSpace: 0, // In pure read-only image, assume filled or calculate from $Bitmap
                isNTFS: true,
                fileSystemName: "Windows NT File System (NTFS)",
                modelName: "Virtuelles NTFS Image",
                vendor: "MacNTFS",
                busProtocol: "Disk Image",
                serialNumber: String(format: "%016llX", boot.volumeSerialNumber),
                isDirty: vol.isDirty,
                clusterSize: boot.clusterSizeBytes,
                isReadOnly: true,
                isSSD: true,
                isSystemDisk: false,
                isInternal: false
            )

            volumeCache[drive.id] = vol
            self.drives.append(drive)
            self.selectedDriveID = drive.id
        } catch {
            self.errorMessage = "Failed to load image: \(error.localizedDescription)"
        }
    }
}
