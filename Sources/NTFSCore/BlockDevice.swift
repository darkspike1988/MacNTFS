import Foundation
import Darwin

/// Protocol defining a readable block-level storage medium (disk image, partition, or raw device).
public protocol BlockDevice: Sendable {
    var size: UInt64 { get }
    func read(offset: UInt64, count: Int) throws -> Data
}

public enum BlockDeviceError: Error, LocalizedError, Sendable {
    case outOfBounds(offset: UInt64, requested: Int, totalSize: UInt64)
    case readFailed(errno: Int32, message: String)
    case invalidFileDescriptor
    case cannotOpenFile(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .outOfBounds(let offset, let requested, let totalSize):
            return "Read out of bounds: offset \(offset) + count \(requested) exceeds total size \(totalSize)"
        case .readFailed(let errno, let message):
            return "Block device read failed (errno \(errno)): \(message)"
        case .invalidFileDescriptor:
            return "Invalid file descriptor"
        case .cannotOpenFile(let path, let message):
            return "Cannot open block device at '\(path)': \(message)"
        }
    }
}

/// A block device implementation backed by a file or raw device node using thread-safe POSIX `pread`.
public final class FileBlockDevice: BlockDevice, @unchecked Sendable {
    private let fd: Int32
    public let size: UInt64
    private let path: String

    public init(path: String) throws {
        self.path = path
        let openFd = Darwin.open(path, O_RDONLY)
        if openFd < 0 {
            let err = errno
            let msg = String(cString: strerror(err))
            throw BlockDeviceError.cannotOpenFile(path: path, message: msg)
        }
        self.fd = openFd

        var statBuf = stat()
        if fstat(openFd, &statBuf) != 0 {
            let err = errno
            Darwin.close(openFd)
            throw BlockDeviceError.cannotOpenFile(path: path, message: "fstat failed: \(String(cString: strerror(err)))")
        }

        // Check if regular file or character/block special device
        let mode = statBuf.st_mode & S_IFMT
        if mode == S_IFCHR || mode == S_IFBLK {
            // For raw devices (like /dev/rdiskX), ioctl DKIOCGETBLOCKCOUNT may be needed,
            // or we use fstat or lseek
            let endPos = Darwin.lseek(openFd, 0, SEEK_END)
            Darwin.lseek(openFd, 0, SEEK_SET)
            self.size = endPos >= 0 ? UInt64(endPos) : UInt64(statBuf.st_size)
        } else {
            self.size = UInt64(statBuf.st_size)
        }
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    public func read(offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        if size > 0 && offset + UInt64(count) > size {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: count, totalSize: size)
        }

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
                // EOF reached
                break
            }
            totalBytesRead += bytesRead
        }

        return Data(buffer.prefix(totalBytesRead))
    }
}

/// An in-memory block device primarily used for testing and mock disks.
public final class MemoryBlockDevice: BlockDevice, @unchecked Sendable {
    private var data: Data

    public var size: UInt64 {
        UInt64(data.count)
    }

    public init(data: Data) {
        self.data = data
    }

    public func read(offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let total = UInt64(data.count)
        if offset + UInt64(count) > total {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: count, totalSize: total)
        }
        let start = Int(offset)
        let end = start + count
        return data.subdata(in: start..<end)
    }

    public func write(offset: UInt64, data toWrite: Data) {
        let end = Int(offset) + toWrite.count
        if end > data.count {
            data.count = end
        }
        data.replaceSubrange(Int(offset)..<end, with: toWrite)
    }
}
