import Foundation
#if canImport(FSKit)
import FSKit
import Darwin

/// Bridge connecting Apple's modern User-Space FSKit architecture to the native Swift NTFS core engine.
@available(macOS 15.4, *)
open class MacNTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {

    public override init() {
        super.init()
    }

    /// Probes an incoming block device / disk resource to verify if it contains a valid NTFS volume.
    open func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let blockResource = resource as? FSBlockDeviceResource else {
            reply(FSProbeResult.notRecognized, nil)
            return
        }

        let bootSectorSize = 512
        Task {
            let bufferPtr = UnsafeMutableRawPointer.allocate(byteCount: bootSectorSize, alignment: 1)
            defer { bufferPtr.deallocate() }

            do {
                let bytesRead = try await blockResource.__read(into: bufferPtr, startingAt: 0, length: bootSectorSize)
                guard bytesRead >= bootSectorSize else {
                    reply(FSProbeResult.notRecognized, nil)
                    return
                }

                let data = Data(bytes: bufferPtr, count: bytesRead)
                let boot = try BootSector(data: data)
                guard boot.oemID == "NTFS    " else {
                    reply(FSProbeResult.notRecognized, nil)
                    return
                }

                let containerID = FSContainerIdentifier(uuid: UUID())
                let probeResult = FSProbeResult.recognized(
                    name: "Windows NTFS",
                    containerID: containerID
                )
                reply(probeResult, nil)
            } catch {
                reply(FSProbeResult.notRecognized, nil)
            }
        }
    }

    /// Loads the probed NTFS resource and presents it to macOS VFS as an active FSVolume.
    open func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let blockResource = resource as? FSBlockDeviceResource else {
            reply(nil, NTFSError.unsupportedFeature("Only FSBlockDeviceResource is supported"))
            return
        }

        let blockDev = FSResourceBlockDevice(resource: blockResource)

        do {
            let coreVolume = try NTFSVolume(blockDevice: blockDev)
            let fsVolume = MacNTFSFSVolume(coreVolume: coreVolume, resource: blockResource)
            reply(fsVolume, nil)
        } catch {
            reply(nil, error)
        }
    }

    open func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        reply(nil)
    }
}

/// An adapter wrapping Apple's `FSBlockDeviceResource` as an `NTFSCore.BlockDevice`.
@available(macOS 15.4, *)
public final class FSResourceBlockDevice: BlockDevice, @unchecked Sendable {
    private let resource: FSBlockDeviceResource
    public let size: UInt64

    public var isWritable: Bool {
        resource.isWritable
    }

    public init(resource: FSBlockDeviceResource) {
        self.resource = resource
        self.size = resource.blockCount * resource.blockSize
    }

    public func read(offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }

        let semaphore = DispatchSemaphore(value: 0)
        var resultData = Data()
        var readError: (any Error)?

        Task {
            let bufferPtr = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
            defer { bufferPtr.deallocate() }

            do {
                let bytesRead = try await self.resource.__read(into: bufferPtr, startingAt: off_t(offset), length: count)
                resultData = Data(bytes: bufferPtr, count: bytesRead)
            } catch {
                readError = error
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let err = readError {
            throw BlockDeviceError.readFailed(errno: 5, message: err.localizedDescription)
        }

        return resultData
    }

    public func write(offset: UInt64, data toWrite: Data) throws {
        guard isWritable else {
            throw BlockDeviceError.readOnlyDevice
        }
        guard !toWrite.isEmpty else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var writeError: (any Error)?

        Task {
            let bufferPtr = UnsafeMutableRawPointer.allocate(byteCount: toWrite.count, alignment: 1)
            defer { bufferPtr.deallocate() }
            toWrite.copyBytes(to: bufferPtr.assumingMemoryBound(to: UInt8.self), count: toWrite.count)

            do {
                _ = try await self.resource.__write(from: bufferPtr, startingAt: off_t(offset), length: toWrite.count)
            } catch {
                writeError = error
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let err = writeError {
            throw BlockDeviceError.writeFailed(errno: 5, message: err.localizedDescription)
        }
    }

    public func flush() throws {
        // Handled by FSKit metadata sync
    }
}

/// Subclass of Apple's `FSVolume` holding our core NTFS engine.
@available(macOS 15.4, *)
open class MacNTFSFSVolume: FSVolume, @unchecked Sendable {
    public let coreVolume: NTFSVolume
    public let resource: FSBlockDeviceResource

    public init(coreVolume: NTFSVolume, resource: FSBlockDeviceResource) {
        self.coreVolume = coreVolume
        self.resource = resource
        let volID = FSVolume.Identifier(uuid: UUID())
        let volName = FSFileName(string: coreVolume.volumeName.isEmpty ? "Windows NTFS" : coreVolume.volumeName)
        super.init(volumeID: volID, volumeName: volName)
    }
}

#endif
