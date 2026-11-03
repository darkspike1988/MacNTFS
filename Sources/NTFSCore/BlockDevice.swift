import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A read-only block storage medium: a disk image, a partition or a raw device.
/// The protocol has no write method, so code that takes a `BlockDevice` cannot change the disk.
public protocol BlockDevice: Sendable {
    var size: UInt64 { get }
    /// Returns exactly `count` bytes or throws. A short read is an error.
    func read(offset: UInt64, count: Int) throws -> Data
}

public enum BlockDeviceError: Error, LocalizedError, Sendable {
    case outOfBounds(offset: UInt64, requested: Int, totalSize: UInt64)
    case readFailed(errno: Int32, message: String)
    case shortRead(offset: UInt64, requested: Int, received: Int)
    case cannotOpenFile(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .outOfBounds(let offset, let requested, let totalSize):
            return "Block device out of bounds: offset \(offset) + count \(requested) exceeds total size \(totalSize)"
        case .readFailed(let errno, let message):
            return "Block device read failed (errno \(errno)): \(message)"
        case .shortRead(let offset, let requested, let received):
            return "Block device returned \(received) of \(requested) bytes at offset \(offset)"
        case .cannotOpenFile(let path, let message):
            return "Cannot open '\(path)': \(message)"
        }
    }
}

/// A block device backed by a file or a raw device node. It is opened read-only.
public final class FileBlockDevice: BlockDevice, @unchecked Sendable {
    private let fd: Int32
    public let size: UInt64
    public let sectorSize: Int
    private let isSectorAlignedDevice: Bool

    public init(path: String) throws {
        let openFd = open(path, O_RDONLY)
        if openFd < 0 {
            throw BlockDeviceError.cannotOpenFile(path: path, message: String(cString: strerror(errno)))
        }

        var statBuf = stat()
        if fstat(openFd, &statBuf) != 0 {
            let err = errno
            close(openFd)
            throw BlockDeviceError.cannotOpenFile(path: path, message: "fstat failed: \(String(cString: strerror(err)))")
        }

        let mode = statBuf.st_mode & mode_t(S_IFMT)
        let isDevice = (mode == mode_t(S_IFCHR) || mode == mode_t(S_IFBLK))

        var detectedSize = UInt64(max(0, statBuf.st_size))
        var detectedSectorSize = 512
        if isDevice {
            #if os(macOS)
            var blockSize: UInt32 = 0
            var blockCount: UInt64 = 0
            let DKIOCGETBLOCKSIZE: UInt = 0x40046418
            let DKIOCGETBLOCKCOUNT: UInt = 0x40086419

            if ioctl(openFd, DKIOCGETBLOCKSIZE, &blockSize) == 0 &&
                ioctl(openFd, DKIOCGETBLOCKCOUNT, &blockCount) == 0 &&
                blockSize > 0 && blockCount > 0 {
                detectedSize = blockCount * UInt64(blockSize)
                detectedSectorSize = Int(blockSize)
            } else {
                let endPosition = lseek(openFd, 0, SEEK_END)
                lseek(openFd, 0, SEEK_SET)
                if endPosition > 0 { detectedSize = UInt64(endPosition) }
            }
            #else
            let endPosition = lseek(openFd, 0, SEEK_END)
            lseek(openFd, 0, SEEK_SET)
            if endPosition > 0 { detectedSize = UInt64(endPosition) }
            #endif
        }

        guard detectedSize > 0 else {
            close(openFd)
            throw BlockDeviceError.cannotOpenFile(path: path, message: "The size is zero or cannot be determined")
        }

        self.fd = openFd
        self.size = detectedSize
        self.sectorSize = detectedSectorSize
        self.isSectorAlignedDevice = isDevice
    }

    deinit {
        close(fd)
    }

    public func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: count, totalSize: size)
        }
        guard count > 0 else { return Data() }

        let sector = UInt64(sectorSize)
        if !isSectorAlignedDevice || (offset % sector == 0 && UInt64(count) % sector == 0) {
            return try readExactly(offset: offset, count: count)
        }

        // Raw devices only accept sector-aligned reads. Read the covering sectors and cut out the part.
        let alignedStart = offset - offset % sector
        let alignedEnd = min(size, ((offset + UInt64(count) + sector - 1) / sector) * sector)
        let aligned = try readExactly(offset: alignedStart, count: Int(alignedEnd - alignedStart))
        let start = Int(offset - alignedStart)
        return aligned.subdata(in: start..<(start + count))
    }

    private func readExactly(offset: UInt64, count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let n = data.withUnsafeMutableBytes { raw -> Int in
                pread(fd, raw.baseAddress!.advanced(by: received), count - received, off_t(offset) + off_t(received))
            }
            if n < 0 {
                if errno == EINTR { continue }
                let err = errno
                throw BlockDeviceError.readFailed(errno: err, message: String(cString: strerror(err)))
            }
            if n == 0 { break }
            received += n
        }
        guard received == count else {
            throw BlockDeviceError.shortRead(offset: offset, requested: count, received: received)
        }
        return data
    }
}

/// An in-memory block device for tests.
public final class MemoryBlockDevice: BlockDevice {
    private let data: Data

    public var size: UInt64 { UInt64(data.count) }

    public init(data: Data) {
        self.data = data
    }

    public func read(offset: UInt64, count: Int) throws -> Data {
        let total = UInt64(data.count)
        guard count >= 0, offset <= total, UInt64(count) <= total - offset else {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: count, totalSize: total)
        }
        guard count > 0 else { return Data() }
        let start = Int(offset)
        return data.subdata(in: start..<(start + count))
    }
}
