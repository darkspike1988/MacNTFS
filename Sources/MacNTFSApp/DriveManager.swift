import Foundation
import Combine
import NTFSCore

public struct DiscoveredDrive: Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var devicePath: String
    public var isDiskImage: Bool
    public var mountPoint: String?
    public var totalCapacity: UInt64
    public var freeSpace: UInt64
    public var isNTFS: Bool
    public var isDirty: Bool
    public var clusterSize: UInt32
    public var serialNumber: String
    public var isReadOnly: Bool

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

    public init() {
        refreshDrives()
    }

    public func getNTFSVolume(for drive: DiscoveredDrive) -> NTFSVolume? {
        if let cached = volumeCache[drive.id] {
            return cached
        }
        guard drive.isNTFS else { return nil }
        do {
            let device = try FileBlockDevice(path: drive.devicePath)
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
                let isInternal = (try? url.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? true

                // Check BSD name via statfs
                var stat = statfs()
                let pathStr = url.path
                var bsdPath = ""
                var fsTypeName = ""
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
                    fsTypeName = fstype.lowercased()
                }

                let isNtfsType = fsTypeName.contains("ntfs") || bsdPath.contains("ntfs")

                // Probe with our native NTFSCore if device is accessible
                var isClean = true
                var clusterSize: UInt32 = 4096
                var serialStr = "N/A"
                if !bsdPath.isEmpty && (isNtfsType || !isInternal) {
                    if let rawDev = try? FileBlockDevice(path: bsdPath),
                       let ntfsVol = try? NTFSVolume(blockDevice: rawDev) {
                        isClean = !ntfsVol.isDirty
                        clusterSize = ntfsVol.bootSector.clusterSizeBytes
                        serialStr = String(format: "%016llX", ntfsVol.bootSector.volumeSerialNumber)
                    }
                }

                let drive = DiscoveredDrive(
                    id: UUID(),
                    name: name,
                    devicePath: bsdPath.isEmpty ? url.path : bsdPath,
                    isDiskImage: false,
                    mountPoint: url.path,
                    totalCapacity: total,
                    freeSpace: available,
                    isNTFS: isNtfsType,
                    isDirty: !isClean,
                    clusterSize: clusterSize,
                    serialNumber: serialStr,
                    isReadOnly: isReadOnly
                )
                found.append(drive)
            }
        }

        // Keep any previously loaded disk images
        for existing in self.drives where existing.isDiskImage {
            found.append(existing)
        }

        self.drives = found
        if selectedDriveID == nil || !found.contains(where: { $0.id == selectedDriveID }) {
            selectedDriveID = found.first(where: { $0.isNTFS })?.id ?? found.first?.id
        }
        self.isScanning = false
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
                isDiskImage: true,
                mountPoint: nil,
                totalCapacity: boot.totalSizeBytes,
                freeSpace: 0, // In pure read-only image, assume filled or calculate from $Bitmap
                isNTFS: true,
                isDirty: vol.isDirty,
                clusterSize: boot.clusterSizeBytes,
                serialNumber: String(format: "%016llX", boot.volumeSerialNumber),
                isReadOnly: true
            )

            volumeCache[drive.id] = vol
            self.drives.append(drive)
            self.selectedDriveID = drive.id
        } catch {
            self.errorMessage = "Failed to load image: \(error.localizedDescription)"
        }
    }
}
