import CFuse3
import Darwin
import Foundation
import NTFSCore

// MacNTFS as a FUSE file system. The NTFS engine runs in this process; macFUSE supplies
// the kernel side (its FSKit backend needs no kernel extension). This is the same split
// as Tuxera NTFS, whose engine is an NTFS-3G-based FUSE low-level daemon.
//
// Inode numbers are MFT record numbers, except the root directory (record 5), which FUSE
// requires to be inode 1. Records 0-15 are system files and are never exposed.
// Requests are served by one thread, so the engine is never entered concurrently.

private let setMode: Int32 = 1 << 0, setSize: Int32 = 1 << 3, setAtime: Int32 = 1 << 4,
            setMtime: Int32 = 1 << 5, setAtimeNow: Int32 = 1 << 7, setMtimeNow: Int32 = 1 << 8

private final class MountedVolume {
    let volume: NTFSVolume
    let readOnly: Bool
    let uid = getuid(), gid = getgid()
    /// Files whose directory index entries still carry an older size or time.
    var pending: Set<UInt64> = []
    var listings: [UInt64: [DirectoryItem]] = [:]
    var usedClusters: UInt64?

    init(volume: NTFSVolume, readOnly: Bool) {
        self.volume = volume
        self.readOnly = readOnly
    }

    func changed() { listings.removeAll(); usedClusters = nil }

    func entries(_ directory: UInt64) throws -> [DirectoryItem] {
        if let cached = listings[directory] { return cached }
        let items = try volume.listDirectory(recordNumber: directory)
        listings[directory] = items
        return items
    }

    func path(_ record: UInt64) throws -> String {
        var components: [String] = []
        var current = record
        while current != 5 {
            guard components.count < 512, let name = try volume.readMFTRecord(number: current).primaryFileName else {
                throw POSIXError(.ENOENT)
            }
            components.append(name.name)
            current = name.parentDirectoryRecordNumber
        }
        return "/" + components.reversed().joined(separator: "/")
    }

    func child(_ parent: UInt64, _ name: String) throws -> String {
        let base = try path(parent)
        return (base == "/" ? "" : base) + "/" + name
    }

    func syncEntry(_ record: UInt64) throws {
        guard pending.contains(record) else { return }
        try volume.syncDirectoryEntry(recordNumber: record)
        pending.remove(record)
        changed()
    }

    func syncAll() throws {
        for record in pending.sorted() { try syncEntry(record) }
    }

    func attributes(_ record: UInt64) throws -> stat {
        let mft = try volume.readMFTRecord(number: record)
        guard mft.isInUse else { throw POSIXError(.ENOENT) }
        var st = stat()
        st.st_ino = inode(record)
        st.st_uid = uid
        st.st_gid = gid
        st.st_blksize = Int32(volume.bootSector.clusterSizeBytes)
        if mft.isDirectory {
            st.st_mode = S_IFDIR | (readOnly ? 0o555 : 0o755)
            st.st_nlink = 2
        } else {
            let size = try volume.dataSize(record: mft)
            st.st_mode = S_IFREG | (readOnly ? 0o444 : 0o644)
            st.st_nlink = 1
            st.st_size = off_t(size.size)
            st.st_blocks = blkcnt_t((size.allocated + 511) / 512)
        }
        if let info = mft.standardInformation {
            st.st_birthtimespec = timespec(info.creationTime)
            st.st_mtimespec = timespec(info.modificationTime)
            st.st_ctimespec = timespec(info.mftModificationTime)
            st.st_atimespec = timespec(info.accessTime)
        }
        st.st_gen = UInt32(mft.header.sequenceNumber)
        return st
    }
}

nonisolated(unsafe) private var mounted: MountedVolume!

private func record(_ inode: fuse_ino_t) -> UInt64 { inode == fuse_ino_t(FUSE_ROOT_ID) ? 5 : inode }
private func inode(_ record: UInt64) -> ino_t { record == 5 ? ino_t(FUSE_ROOT_ID) : ino_t(record) }
private func timespec(_ date: Date) -> Darwin.timespec {
    let seconds = date.timeIntervalSince1970.rounded(.down)
    return Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1e9))
}
private func date(_ time: Darwin.timespec) -> Date {
    Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
}

private func errnoValue(_ error: Error) -> Int32 {
    switch error {
    case let error as POSIXError: return error.code.rawValue
    case let error as NSError where error.domain == NSPOSIXErrorDomain: return Int32(error.code)
    case NTFSError.pathNotFound, NTFSError.recordNotAllocated: return ENOENT
    case NTFSError.notADirectory: return ENOTDIR
    case BlockDeviceError.readOnlyDevice: return EROFS
    case NTFSError.unsupportedFeature(let reason):
        if reason.contains("already exists") { return EEXIST }
        if reason.contains("Insufficient free") { return ENOSPC }
        if reason.contains("at most 255") { return ENAMETOOLONG }
        return ENOTSUP
    default: return EIO
    }
}

private func reply(_ req: fuse_req_t?, _ body: () throws -> Void) {
    do { try body() } catch {
        let code = errnoValue(error)
        if code == EIO { FileHandle.standardError.write(Data("macntfs-fuse: \(error)\n".utf8)) }
        fuse_reply_err(req, code)
    }
}

private func entryParam(_ record: UInt64) throws -> fuse_entry_param {
    var entry = fuse_entry_param()
    entry.ino = fuse_ino_t(inode(record))
    entry.attr = try mounted.attributes(record)
    entry.generation = UInt64(entry.attr.st_gen)
    entry.attr_timeout = 1
    entry.entry_timeout = 1
    return entry
}

private func requireWritable() throws {
    if mounted.readOnly { throw POSIXError(.EROFS) }
}

/// NTFS forbids some characters that POSIX allows; refuse rather than silently rename.
private func ntfsName(_ name: UnsafePointer<CChar>?) throws -> String {
    guard let name, let string = String(validatingCString: name), !string.isEmpty,
          NTFSVolumeWriter.sanitizeFileName(string) == string else { throw POSIXError(.EINVAL) }
    guard string.utf16.count <= 255 else { throw POSIXError(.ENAMETOOLONG) }
    return string
}

private func makeOperations() -> fuse_lowlevel_ops {
    var ops = fuse_lowlevel_ops()
    ops.destroy = { _ in
        try? mounted.syncAll()
        try? mounted.volume.blockDevice.flush()
    }
    ops.lookup = { req, parent, name in
        reply(req) {
            guard let name, let wanted = String(validatingCString: name) else { throw POSIXError(.EINVAL) }
            guard let match = try mounted.entries(record(parent)).first(where: {
                $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame
            }) else { throw POSIXError(.ENOENT) }
            var entry = try entryParam(match.mftRecordNumber)
            fuse_reply_entry(req, &entry)
        }
    }
    ops.getattr = { req, ino, _ in
        reply(req) {
            var st = try mounted.attributes(record(ino))
            fuse_reply_attr(req, &st, 1)
        }
    }
    ops.setattr = { req, ino, attr, toSet, _ in
        reply(req) {
            let number = record(ino)
            if toSet & setSize != 0, let attr {
                try requireWritable()
                try mounted.volume.truncate(recordNumber: number, size: UInt64(attr.pointee.st_size), updateDirectory: false)
                mounted.pending.insert(number)
                mounted.changed()
            }
            if toSet & (setMtime | setAtime | setMtimeNow | setAtimeNow) != 0, let attr {
                try requireWritable()
                try mounted.syncEntry(number)
                let now = Date()
                let modification = toSet & setMtimeNow != 0 ? now : toSet & setMtime != 0 ? date(attr.pointee.st_mtimespec) : nil
                let access = toSet & setAtimeNow != 0 ? now : toSet & setAtime != 0 ? date(attr.pointee.st_atimespec) : nil
                try mounted.volume.setFileTimes(recordNumber: number, modification: modification, access: access)
                mounted.changed()
            }
            _ = setMode // Permissions are not stored on NTFS; mode changes are accepted and ignored.
            var st = try mounted.attributes(number)
            fuse_reply_attr(req, &st, 1)
        }
    }
    ops.readdir = { req, ino, size, offset, _ in
        reply(req) {
            let directory = record(ino)
            var entries: [(String, UInt64, Bool)] = [(".", directory, true)]
            let parent = directory == 5 ? 5 : (try mounted.volume.readMFTRecord(number: directory).primaryFileName?.parentDirectoryRecordNumber ?? 5)
            entries.append(("..", parent, true))
            entries += try mounted.entries(directory).map { ($0.name, $0.mftRecordNumber, $0.isDirectory) }
            var buffer = [CChar](repeating: 0, count: size)
            var used = 0
            var index = Int(offset)
            while index < entries.count {
                var st = stat()
                st.st_ino = inode(entries[index].1)
                st.st_mode = entries[index].2 ? S_IFDIR : S_IFREG
                let needed = buffer.withUnsafeMutableBufferPointer { pointer in
                    fuse_add_direntry(req, pointer.baseAddress! + used, size - used, entries[index].0, &st, off_t(index + 1))
                }
                if needed > size - used { break }
                used += needed
                index += 1
            }
            fuse_reply_buf(req, buffer, used)
        }
    }
    ops.open = { req, ino, fi in
        reply(req) {
            if let fi, fi.pointee.flags & O_ACCMODE != O_RDONLY { try requireWritable() }
            fuse_reply_open(req, fi)
        }
    }
    ops.read = { req, ino, size, offset, _ in
        reply(req) {
            let mft = try mounted.volume.readMFTRecord(number: record(ino))
            let data = try mounted.volume.readData(record: mft, offset: UInt64(offset), length: size)
            data.withUnsafeBytes { _ = fuse_reply_buf(req, $0.baseAddress, data.count) }
        }
    }
    ops.write = { req, ino, buffer, size, offset, _ in
        reply(req) {
            try requireWritable()
            let number = record(ino)
            try mounted.volume.writeData(recordNumber: number, offset: UInt64(offset),
                                         data: Data(bytes: buffer!, count: size), updateDirectory: false)
            mounted.pending.insert(number)
            mounted.usedClusters = nil
            fuse_reply_write(req, size)
        }
    }
    ops.flush = { req, ino, _ in reply(req) { try mounted.syncEntry(record(ino)); fuse_reply_err(req, 0) } }
    ops.release = { req, ino, _ in reply(req) { try mounted.syncEntry(record(ino)); fuse_reply_err(req, 0) } }
    ops.fsync = { req, ino, _, _ in
        reply(req) {
            try mounted.syncEntry(record(ino))
            try mounted.volume.blockDevice.flush()
            fuse_reply_err(req, 0)
        }
    }
    ops.create = { req, parent, name, _, fi in
        reply(req) {
            try requireWritable()
            let fileName = try ntfsName(name)
            let number = try mounted.volume.writeFile(fileName: fileName, data: Data(), directoryPath: mounted.path(record(parent)))
            mounted.changed()
            var entry = try entryParam(number)
            fuse_reply_create(req, &entry, fi)
        }
    }
    ops.mkdir = { req, parent, name, _ in
        reply(req) {
            try requireWritable()
            let number = try mounted.volume.createDirectory(name: ntfsName(name), directoryPath: mounted.path(record(parent)))
            mounted.changed()
            var entry = try entryParam(number)
            fuse_reply_entry(req, &entry)
        }
    }
    let remove: @convention(c) (fuse_req_t?, fuse_ino_t, UnsafePointer<CChar>?) -> Void = { req, parent, name in
        reply(req) {
            try requireWritable()
            guard let name, let fileName = String(validatingCString: name) else { throw POSIXError(.EINVAL) }
            let directory = try mounted.path(record(parent))
            if let match = try mounted.entries(record(parent)).first(where: { $0.name == fileName }) {
                mounted.pending.remove(match.mftRecordNumber)
            }
            try mounted.volume.removeItem(name: fileName, directoryPath: directory)
            mounted.changed()
            fuse_reply_err(req, 0)
        }
    }
    ops.unlink = remove
    ops.rmdir = remove
    ops.rename = { req, parent, name, newParent, newName, flags in
        reply(req) {
            try requireWritable()
            guard let name, let source = String(validatingCString: name) else { throw POSIXError(.EINVAL) }
            let target = try ntfsName(newName)
            // Darwin renamex_np: RENAME_SWAP (2) is not supported, RENAME_EXCL (4) forbids replacing.
            guard flags & 2 == 0 else { throw POSIXError(.ENOTSUP) }
            if let match = try mounted.entries(record(parent)).first(where: { $0.name == source }) {
                try mounted.syncEntry(match.mftRecordNumber)
            }
            try mounted.volume.renameItem(sourcePath: mounted.child(record(parent), source),
                                          destinationPath: mounted.child(record(newParent), target),
                                          replaceExisting: flags & 5 == 0)
            mounted.changed()
            fuse_reply_err(req, 0)
        }
    }
    ops.statfs = { req, _ in
        reply(req) {
            let boot = mounted.volume.bootSector
            let cluster = UInt64(boot.clusterSizeBytes)
            let total = boot.totalSizeBytes / cluster
            if mounted.usedClusters == nil {
                let bitmap = try mounted.volume.readData(record: mounted.volume.readMFTRecord(number: 6))
                mounted.usedClusters = bitmap.reduce(UInt64(0)) { $0 + UInt64($1.nonzeroBitCount) }
            }
            let free = total > mounted.usedClusters! ? total - mounted.usedClusters! : 0
            var st = statvfs()
            st.f_bsize = UInt(cluster)
            st.f_frsize = UInt(cluster)
            st.f_blocks = fsblkcnt_t(min(total, UInt64(fsblkcnt_t.max)))
            st.f_bfree = fsblkcnt_t(min(free, UInt64(fsblkcnt_t.max)))
            st.f_bavail = st.f_bfree
            st.f_files = fsfilcnt_t(UInt32.max)
            st.f_ffree = fsfilcnt_t(UInt32.max)
            st.f_favail = st.f_ffree
            st.f_namemax = 255
            fuse_reply_statfs(req, &st)
        }
    }
    return ops
}

// MARK: Entry point

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("""
    Usage: macntfs-fuse <device-or-image> <mount-point> [-o option,...] [-f]
      Mounts an NTFS volume with macFUSE. Writes are refused, and the volume is mounted
      read-only, while Windows is hibernated, the volume is dirty, or the journal is unclean.
      -o ro           mount read-only
      -o backend=kext use macFUSE's kernel extension instead of FSKit
      -f              stay in the foreground
    """)
    exit(2)
}
let source = arguments[1], mountPoint = arguments[2]
var extra = Array(arguments.dropFirst(3))
var options: [String] = []
var foreground = false
var index = 0
while index < extra.count {
    if extra[index] == "-o", index + 1 < extra.count { options += extra[index + 1].split(separator: ",").map(String.init); index += 2 }
    else if extra[index] == "-f" { foreground = true; index += 1 }
    else { index += 1 }
}
extra.removeAll()

// fork() is unsafe once Foundation has started threads, so instead of fuse_daemonize the
// command restarts itself in the foreground, detached, and returns once the mount appears.
if !foreground {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = Array(arguments.dropFirst()) + ["-f"]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    child.standardError = errors
    try child.run()
    var before = statfs(), now = statfs()
    statfs(mountPoint, &before)
    for _ in 0..<100 where child.isRunning {
        usleep(100_000)
        if statfs(mountPoint, &now) == 0, now.f_fsid.val.0 != before.f_fsid.val.0 { exit(0) }
    }
    if child.isRunning { exit(0) }
    FileHandle.standardError.write(errors.fileHandleForReading.readDataToEndOfFile())
    exit(child.terminationStatus == 0 ? 1 : child.terminationStatus)
}

var readOnly = options.contains("ro") || options.contains("rdonly")
do {
    var device: BlockDevice = try FileBlockDevice(path: source, writable: !readOnly)
    var volume = try NTFSVolume(blockDevice: device)
    if !readOnly, let issue = NTFSVolumeWriter.writeSafetyIssue(volume) {
        FileHandle.standardError.write(Data("macntfs-fuse: mounting read-only: \(issue)\n".utf8))
        readOnly = true
        device = try FileBlockDevice(path: source, writable: false)
        volume = try NTFSVolume(blockDevice: device)
    }
    mounted = MountedVolume(volume: volume, readOnly: readOnly)
    options.removeAll { $0 == "ro" || $0 == "rdonly" }
    if !options.contains(where: { $0.hasPrefix("backend=") }) { options.append("backend=fskit") }
    if !options.contains(where: { $0.hasPrefix("volname=") }) { options.append("volname=" + volume.volumeName) }
    options += ["fsname=macntfs@" + (source as NSString).lastPathComponent, "local"]
    if readOnly { options.append("ro") }
} catch {
    FileHandle.standardError.write(Data("macntfs-fuse: cannot open \(source): \(error)\n".utf8))
    exit(1)
}

let argumentStrings = [arguments[0], "-o", options.joined(separator: ",")]
let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argumentStrings.count + 1)
for (i, value) in argumentStrings.enumerated() { argv[i] = strdup(value) }
argv[argumentStrings.count] = nil
var fuseArguments = fuse_args(argc: Int32(argumentStrings.count), argv: argv, allocated: 0)
var operations = makeOperations()
guard let session = fuse_session_new_fn(&fuseArguments, &operations, MemoryLayout<fuse_lowlevel_ops>.size, nil) else {
    FileHandle.standardError.write(Data("macntfs-fuse: invalid FUSE options\n".utf8))
    exit(1)
}
guard fuse_set_signal_handlers(session) == 0, fuse_session_mount(session, mountPoint) == 0 else {
    FileHandle.standardError.write(Data("macntfs-fuse: mounting \(mountPoint) failed\n".utf8))
    exit(1)
}
let status = fuse_session_loop(session)
fuse_session_unmount(session)
fuse_remove_signal_handlers(session)
fuse_session_destroy(session)
exit(status == 0 ? 0 : 1)
