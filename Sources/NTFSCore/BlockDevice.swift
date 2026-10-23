import Foundation
import Darwin

/// Protocol defining a block-level storage medium (disk image, partition, or raw device) supporting read and write operations.
public protocol BlockDevice: Sendable {
    var size: UInt64 { get }
    var isWritable: Bool { get }
    func read(offset: UInt64, count: Int) throws -> Data
    func write(offset: UInt64, data: Data) throws
    func flush() throws
}

public enum BlockDeviceError: Error, LocalizedError, Sendable {
    case outOfBounds(offset: UInt64, requested: Int, totalSize: UInt64)
    case readFailed(errno: Int32, message: String)
    case writeFailed(errno: Int32, message: String)
    case readOnlyDevice
    case invalidFileDescriptor
    case cannotOpenFile(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .outOfBounds(let offset, let requested, let totalSize):
            return "Block device out of bounds: offset \(offset) + count \(requested) exceeds total size \(totalSize)"
        case .readFailed(let errno, let message):
            return "Block device read failed (errno \(errno)): \(message)"
        case .writeFailed(let errno, let message):
            return "Block device write failed (errno \(errno)): \(message)"
        case .readOnlyDevice:
            return "Block device is opened in read-only mode"
        case .invalidFileDescriptor:
            return "Invalid file descriptor"
        case .cannotOpenFile(let path, let message):
            return "Cannot open block device at '\(path)': \(message)"
        }
    }
}

/// A block device implementation backed by a file or raw device node using thread-safe POSIX `pread` and `pwrite`.
public final class FileBlockDevice: BlockDevice, @unchecked Sendable {
    private let fd: Int32
    public let size: UInt64
    public let isWritable: Bool
    public let sectorSize: Int
    private let isSectorAlignedDevice: Bool
    /// Raw devices need a complete, validated on-disk formatter, unlike test images.
    public var isRawDevice: Bool { isSectorAlignedDevice }
    private let path: String
    private static let mountTableLock = NSLock()

    /// Resolve symlinks and the raw/block aliases of the same disk.
    internal static func canonicalDevicePath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix("/dev/rdisk")
            ? resolved.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
            : resolved
    }

    /// Whole-disk writes also overlap any mounted child partition.
    internal static func deviceConflictsWithMount(devicePath: String, mountSource: String) -> Bool {
        let device = canonicalDevicePath(devicePath)
        let source = canonicalDevicePath(mountSource)
        if source == device { return true }
        guard device.hasPrefix("/dev/disk") else { return false }
        let diskNumber = device.dropFirst("/dev/disk".count)
        let isWholeDisk = !diskNumber.isEmpty && diskNumber.allSatisfy { $0.isASCII && $0.isNumber }
        return isWholeDisk && source.hasPrefix(device + "s")
    }

    /// Only called for descriptors confirmed by fstat to be device nodes.
    /// Rechecking narrows the mount race; raw access still needs exclusive ownership.
    internal static func ensureUnmountedDevice(at path: String) throws {
        let canonical = canonicalDevicePath(path)
        guard canonical.hasPrefix("/dev/disk"),
              !canonical.dropFirst("/dev/disk".count).isEmpty else {
            throw BlockDeviceError.writeFailed(errno: EBUSY, message: "Cannot establish mount safety for device '\(path)'")
        }
        mountTableLock.lock()
        defer { mountTableLock.unlock() }
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else {
            throw BlockDeviceError.writeFailed(errno: EBUSY, message: "Cannot determine current mount status; raw write refused")
        }
        for index in 0..<Int(count) {
            var entry = entries[index]
            let source = withUnsafePointer(to: &entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
            }
            if deviceConflictsWithMount(devicePath: canonical, mountSource: source) {
                throw BlockDeviceError.writeFailed(errno: EBUSY, message: "Device '\(path)' or a child partition is mounted at '\(source)'; raw write refused")
            }
        }
    }

    public init(path: String, writable: Bool = false, allowReadOnlyFallback: Bool = false) throws {
        let openPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.path = Self.canonicalDevicePath(openPath)

        let flags = writable ? O_RDWR : O_RDONLY
        var openFd = Darwin.open(openPath, flags)
        var actualWritable = writable

        // Fallback to read-only only if explicitly permitted
        if openFd < 0 && writable && allowReadOnlyFallback {
            openFd = Darwin.open(openPath, O_RDONLY)
            actualWritable = false
        }

        if openFd < 0 {
            let err = errno
            let msg = String(cString: strerror(err))
            let hint = writable && (err == EACCES || err == EPERM)
                ? " Write access to raw block devices on macOS requires administrative privileges (sudo) or Full Disk Access."
                : ""
            throw BlockDeviceError.cannotOpenFile(path: path, message: "\(msg).\(hint)")
        }

        var statBuf = stat()
        if fstat(openFd, &statBuf) != 0 {
            let err = errno
            Darwin.close(openFd)
            throw BlockDeviceError.cannotOpenFile(path: path, message: "fstat failed: \(String(cString: strerror(err)))")
        }

        let mode = statBuf.st_mode & S_IFMT
        let isDevice = (mode == S_IFCHR || mode == S_IFBLK)
        self.isSectorAlignedDevice = isDevice

        if isDevice && actualWritable {
            do {
                try Self.ensureUnmountedDevice(at: self.path)
            } catch {
                Darwin.close(openFd)
                guard allowReadOnlyFallback else { throw error }
                openFd = Darwin.open(openPath, O_RDONLY)
                guard openFd >= 0 else {
                    throw BlockDeviceError.cannotOpenFile(path: path, message: "Cannot reopen mounted device read-only")
                }
                actualWritable = false
            }
        }
        self.fd = openFd
        self.isWritable = actualWritable

        var detectedSectorSize = 512
        if isDevice {
            #if os(macOS)
            var blockSize: UInt32 = 0
            var blockCount: UInt64 = 0
            let DKIOCGETBLOCKSIZE: UInt = 0x40046418
            let DKIOCGETBLOCKCOUNT: UInt = 0x40086419

            if Darwin.ioctl(openFd, DKIOCGETBLOCKSIZE, &blockSize) == 0 &&
               Darwin.ioctl(openFd, DKIOCGETBLOCKCOUNT, &blockCount) == 0 &&
               blockSize > 0 && blockCount > 0 {
                self.size = blockCount * UInt64(blockSize)
                detectedSectorSize = Int(blockSize)
            } else {
                let endPos = Darwin.lseek(openFd, 0, SEEK_END)
                Darwin.lseek(openFd, 0, SEEK_SET)
                self.size = endPos > 0 ? UInt64(endPos) : UInt64(statBuf.st_size)
            }
            #else
            let endPos = Darwin.lseek(openFd, 0, SEEK_END)
            Darwin.lseek(openFd, 0, SEEK_SET)
            self.size = endPos >= 0 ? UInt64(endPos) : UInt64(statBuf.st_size)
            #endif
        } else {
            self.size = UInt64(statBuf.st_size)
        }
        self.sectorSize = detectedSectorSize
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    private func alignedReadDirect(offset: UInt64, count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var totalBytesRead = 0

        while totalBytesRead < count {
            let currentOffset = off_t(offset) + off_t(totalBytesRead)
            let remaining = count - totalBytesRead
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                guard let baseAddr = rawBuf.baseAddress else { return -1 }
                let ptr = baseAddr.advanced(by: totalBytesRead)
                return Darwin.pread(fd, ptr, remaining, currentOffset)
            }

            if bytesRead < 0 {
                let err = errno
                throw BlockDeviceError.readFailed(errno: err, message: String(cString: strerror(err)))
            }
            if bytesRead == 0 {
                break
            }
            totalBytesRead += bytesRead
        }

        return Data(buffer.prefix(totalBytesRead))
    }

    public func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset,
              offset <= UInt64(Int64.max), UInt64(count) <= UInt64(Int64.max) - offset else {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: count, totalSize: size)
        }
        guard count > 0 else { return Data() }

        if !isSectorAlignedDevice {
            return try alignedReadDirect(offset: offset, count: count)
        }

        let sSize = UInt64(sectorSize)
        if offset % sSize == 0 && count % sectorSize == 0 {
            return try alignedReadDirect(offset: offset, count: count)
        }

        // Sector bounce buffer read for unaligned offset or length
        let alignedStart = (offset / sSize) * sSize
        let alignedEnd = ((offset + UInt64(count) + sSize - 1) / sSize) * sSize
        let alignedCount = Int(alignedEnd - alignedStart)

        let alignedData = try alignedReadDirect(offset: alignedStart, count: alignedCount)
        let subStart = Int(offset - alignedStart)
        guard subStart < alignedData.count else { return Data() }
        let available = alignedData.count - subStart
        let sliceCount = min(count, available)
        return alignedData.subdata(in: subStart..<(subStart + sliceCount))
    }

    private func alignedWriteDirect(offset: UInt64, data toWrite: Data) throws {
        let count = toWrite.count
        var totalBytesWritten = 0

        while totalBytesWritten < count {
            if isSectorAlignedDevice {
                try Self.ensureUnmountedDevice(at: path)
            }
            let currentOffset = off_t(offset) + off_t(totalBytesWritten)
            let remaining = count - totalBytesWritten

            let bytesWritten = toWrite.withUnsafeBytes { rawBuf -> Int in
                guard let baseAddr = rawBuf.baseAddress else { return -1 }
                let ptr = baseAddr.advanced(by: totalBytesWritten)
                return Darwin.pwrite(fd, ptr, remaining, currentOffset)
            }

            if bytesWritten < 0 {
                let err = errno
                throw BlockDeviceError.writeFailed(errno: err, message: String(cString: strerror(err)))
            }
            guard bytesWritten > 0 else {
                throw BlockDeviceError.writeFailed(errno: EIO, message: "pwrite made no progress")
            }
            totalBytesWritten += bytesWritten
        }
    }

    public func write(offset: UInt64, data toWrite: Data) throws {
        guard isWritable else {
            throw BlockDeviceError.readOnlyDevice
        }
        guard offset <= size, UInt64(toWrite.count) <= size - offset,
              offset <= UInt64(Int64.max), UInt64(toWrite.count) <= UInt64(Int64.max) - offset else {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: toWrite.count, totalSize: size)
        }
        guard !toWrite.isEmpty else { return }

        if !isSectorAlignedDevice {
            try alignedWriteDirect(offset: offset, data: toWrite)
            return
        }

        let sSize = UInt64(sectorSize)
        if offset % sSize == 0 && toWrite.count % sectorSize == 0 {
            try alignedWriteDirect(offset: offset, data: toWrite)
            return
        }

        // Sector bounce buffer write (Read-Modify-Write for raw devices)
        let alignedStart = (offset / sSize) * sSize
        let writeEnd = offset + UInt64(toWrite.count)
        let padding = (sSize - writeEnd % sSize) % sSize
        guard padding <= size - writeEnd else {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: toWrite.count, totalSize: size)
        }
        let alignedEnd = writeEnd + padding
        let alignedCount = Int(alignedEnd - alignedStart)

        var bounceBuffer = try alignedReadDirect(offset: alignedStart, count: alignedCount)
        guard bounceBuffer.count == alignedCount else {
            throw BlockDeviceError.readFailed(errno: EIO, message: "Short sector read during read-modify-write")
        }

        let subStart = Int(offset - alignedStart)
        bounceBuffer.replaceSubrange(subStart..<(subStart + toWrite.count), with: toWrite)

        try alignedWriteDirect(offset: alignedStart, data: bounceBuffer)
    }

    public func flush() throws {
        guard isWritable else { return }
        if isSectorAlignedDevice {
            try Self.ensureUnmountedDevice(at: path)
        }
        if Darwin.fsync(fd) != 0 {
            let err = errno
            throw BlockDeviceError.writeFailed(errno: err, message: "fsync failed: \(String(cString: strerror(err)))")
        }
    }
}

/// An in-memory block device primarily used for testing and mock disks.
public final class MemoryBlockDevice: BlockDevice, @unchecked Sendable {
    private var data: Data
    public var isWritable: Bool = true

    public var size: UInt64 {
        UInt64(data.count)
    }

    public init(data: Data, writable: Bool = true) {
        self.data = data
        self.isWritable = writable
    }

    public func read(offset: UInt64, count: Int) throws -> Data {
        let total = UInt64(data.count)
        guard count >= 0, offset <= total, UInt64(count) <= total - offset else {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: count, totalSize: total)
        }
        guard count > 0 else { return Data() }
        let start = Int(offset)
        let end = start + count
        return data.subdata(in: start..<end)
    }

    public func write(offset: UInt64, data toWrite: Data) throws {
        guard isWritable else {
            throw BlockDeviceError.readOnlyDevice
        }
        let total = UInt64(data.count)
        guard offset <= total, UInt64(toWrite.count) <= total - offset else {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: toWrite.count, totalSize: total)
        }
        let end = Int(offset) + toWrite.count
        data.replaceSubrange(Int(offset)..<end, with: toWrite)
    }

    public func flush() throws {
        // In-memory data is always persistent for the lifetime of the object
    }
}
