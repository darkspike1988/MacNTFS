#if canImport(FSKit) && NTFS_FSKIT
import Foundation
import FSKit
import NTFSCore

/// The NTFS file system for FSKit: it probes a block device resource and presents it as one read-only volume.
@available(macOS 27.0, *)
public final class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    public func probeResource(resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else {
            reply(FSProbeResult.notRecognized, nil)
            return
        }
        let block = ResourceBlockDevice(resource: device)
        let boot: BootSector
        do {
            boot = try BootSector(data: try block.read(offset: 0, count: 512))
        } catch {
            reply(FSProbeResult.notRecognized, nil)
            return
        }
        let containerID = FSContainerIdentifier(uuid: Self.uuid(serial: boot.volumeSerialNumber))
        guard let volume = try? NTFSVolume(blockDevice: block) else {
            // A NTFS boot sector, but the volume cannot be opened: known, not usable.
            reply(FSProbeResult.recognized(name: "NTFS", containerID: containerID), nil)
            return
        }
        // A dirty volume or one with a saved hibernation state can show outdated data: usable, but limited.
        let hibernated = (try? volume.hibernationState()) == .hibernated
        if volume.isDirty || !volume.volumeFlagsKnown || hibernated {
            reply(FSProbeResult.usableButLimited(name: volume.volumeName, containerID: containerID), nil)
        } else {
            reply(FSProbeResult.usable(name: volume.volumeName, containerID: containerID), nil)
        }
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else {
            reply(nil, posixError(EINVAL))
            return
        }
        do {
            // Whatever the options say, this volume is read-only: the engine has no way to write.
            let volume = try NTFSVolume(blockDevice: ResourceBlockDevice(resource: device))
            let uuid = Self.uuid(serial: volume.bootSector.volumeSerialNumber)
            let result = NTFSFSVolume(
                fileSystem: ReadOnlyFileSystem(volume: volume),
                volumeID: FSVolume.Identifier(uuid: uuid),
                name: FSFileName(string: volume.volumeName)
            )
            containerStatus = .active
            reply(result, nil)
        } catch {
            reply(nil, FileSystemError(error).nsError)
        }
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    /// A stable UUID for a volume: the 64-bit serial number of the boot sector in the last eight bytes.
    static func uuid(serial: UInt64) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x4E; bytes[1] = 0x54; bytes[2] = 0x46; bytes[3] = 0x53  // "NTFS"
        for index in 0..<8 { bytes[8 + index] = UInt8((serial >> UInt64(56 - 8 * index)) & 0xFF) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// The extension entry point. The app extension target (Xcode) marks a type like this with `@main`.
@available(macOS 27.0, *)
public struct NTFSFileSystemExtension: UnaryFileSystemExtension {
    public let fileSystem = NTFSFileSystem()
    public init() {}
}

func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

extension FileSystemError {
    /// The error in the form FSKit expects: a POSIX error.
    var nsError: NSError { posixError(posixCode) }
}
#endif
