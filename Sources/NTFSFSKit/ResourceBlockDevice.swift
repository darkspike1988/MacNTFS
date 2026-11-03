#if canImport(FSKit)
import Foundation
import FSKit
import NTFSCore

/// An `FSBlockDeviceResource` as a `BlockDevice`. The type has no write method, so the engine cannot write through it.
/// Reads are aligned to the block size of the resource and done in pieces of at most one MiB.
@available(macOS 15.4, *)
final class ResourceBlockDevice: BlockDevice, @unchecked Sendable {
    private let resource: FSBlockDeviceResource
    private let blockSize: UInt64
    let size: UInt64

    private static let pieceLimit: UInt64 = 1 << 20

    init(resource: FSBlockDeviceResource) {
        self.resource = resource
        self.blockSize = max(1, resource.blockSize)
        self.size = resource.blockSize &* resource.blockCount
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw BlockDeviceError.outOfBounds(offset: offset, requested: count, totalSize: size)
        }
        if count == 0 { return Data() }

        let start = offset / blockSize * blockSize
        let end = (offset + UInt64(count) + blockSize - 1) / blockSize * blockSize
        var result = Data(capacity: count)
        var position = start
        while position < end {
            let length = min(end - position, Self.pieceLimit / blockSize * blockSize)
            var buffer = [UInt8](repeating: 0, count: Int(length))
            let received: Int
            do {
                received = try buffer.withUnsafeMutableBytes { raw in
                    try resource.read(into: raw, startingAt: off_t(position), length: Int(length))
                }
            } catch {
                throw BlockDeviceError.readFailed(errno: EIO, message: error.localizedDescription)
            }
            guard received == Int(length) else {
                throw BlockDeviceError.shortRead(offset: position, requested: Int(length), received: received)
            }
            // Keep only the bytes inside the requested range.
            let pieceStart = max(position, offset)
            let pieceEnd = min(position + length, offset + UInt64(count))
            result.append(contentsOf: buffer[Int(pieceStart - position)..<Int(pieceEnd - position)])
            position += length
        }
        return result
    }
}
#endif
