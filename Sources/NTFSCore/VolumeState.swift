import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether Windows left the volume in hibernation or Fast Startup. Windows keeps the state of the
/// system in `hiberfil.sys` and starts it with the magic `hibr`. While that state exists, the
/// file system on disk is not up to date, and reading it can show outdated data.
public enum HibernationState: Sendable, Equatable {
    /// There is no `hiberfil.sys` in the root directory.
    case absent
    /// `hiberfil.sys` exists, but does not hold a saved system state (Windows has resumed from it, or it is new).
    case notHibernated
    /// `hiberfil.sys` holds a saved system state: hibernation or Fast Startup.
    case hibernated
}

extension NTFSVolume {
    /// Looks at the first bytes of `\hiberfil.sys` in the root directory.
    public func hibernationState() throws -> HibernationState {
        let record: MFTRecord
        do {
            record = try lookup(path: "/hiberfil.sys").record
        } catch NTFSError.pathNotFound {
            return .absent
        }
        let header = try readData(record: record, offset: 0, length: 4)
        // "hibr" is a saved state. "HIBR" is the same, written by some Windows versions.
        if header == Data("hibr".utf8) || header == Data("HIBR".utf8) {
            return .hibernated
        }
        return .notHibernated
    }
}

/// A mounted file system.
public struct MountInfo: Sendable, Equatable {
    /// The device node the file system was mounted from, for example `/dev/disk4s1`.
    public let device: String
    public let mountPoint: String
    public let fileSystemType: String
    public let isReadOnly: Bool

    public init(device: String, mountPoint: String, fileSystemType: String, isReadOnly: Bool) {
        self.device = device
        self.mountPoint = mountPoint
        self.fileSystemType = fileSystemType
        self.isReadOnly = isReadOnly
    }
}

public enum MountCheck {
    /// The mount of a device, found by its path. `/dev/rdisk4s1` (raw) and `/dev/disk4s1` are the same device.
    public static func mount(forDevice path: String, in mounts: [MountInfo]) -> MountInfo? {
        let wanted = normalized(path)
        return mounts.first { normalized($0.device) == wanted }
    }

    /// All file systems that are mounted now. Empty on platforms without `getmntinfo`.
    public static func currentMounts() -> [MountInfo] {
        #if canImport(Darwin)
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list else { return [] }
        return (0..<Int(count)).map { index in
            var entry = list[index]
            func text<T>(_ field: inout T) -> String {
                withUnsafeBytes(of: &field) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            return MountInfo(
                device: text(&entry.f_mntfromname),
                mountPoint: text(&entry.f_mntonname),
                fileSystemType: text(&entry.f_fstypename),
                isReadOnly: entry.f_flags & UInt32(MNT_RDONLY) != 0
            )
        }
        #else
        return []
        #endif
    }

    private static func normalized(_ path: String) -> String {
        path.hasPrefix("/dev/r") ? "/dev/" + path.dropFirst("/dev/r".count) : path
    }
}
