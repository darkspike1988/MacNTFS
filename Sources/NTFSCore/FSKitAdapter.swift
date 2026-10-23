import Foundation
#if canImport(FSKit)
import FSKit
import Darwin

/// The FSKit boundary is synchronous: the NTFS engine never waits on a Swift task.
@available(macOS 15.4, *)
public final class FSResourceBlockDevice: BlockDevice, @unchecked Sendable {
    public let resource: FSBlockDeviceResource
    public let size: UInt64
    public var isWritable: Bool { resource.isWritable && !readOnly }
    private let readOnly: Bool
    private let lock = NSRecursiveLock()
    public init(resource: FSBlockDeviceResource, readOnly: Bool = false) {
        self.readOnly = readOnly
        self.resource = resource
        size = resource.blockCount * resource.blockSize
    }
    public func read(offset: UInt64, count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw posix(EINVAL) }
        guard count > 0 else { return Data() }
        let sector = max(512, Int(resource.physicalBlockSize), Int(resource.blockSize))
        let start = offset / UInt64(sector) * UInt64(sector)
        let skip = Int(offset - start)
        let length = ((skip + count + sector - 1) / sector) * sector
        var bytes = Data(count: length)
        let actual = try bytes.withUnsafeMutableBytes { try resource.read(into: $0, startingAt: off_t(start), length: length) }
        guard actual == length else { throw posix(EIO) }
        return bytes.subdata(in: skip..<(skip + count))
    }
    public func write(offset: UInt64, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard isWritable else { throw posix(EROFS) }
        guard offset <= size, UInt64(data.count) <= size - offset else { throw posix(EINVAL) }
        guard !data.isEmpty else { return }
        let sector = max(512, Int(resource.physicalBlockSize), Int(resource.blockSize))
        let start = offset / UInt64(sector) * UInt64(sector)
        let skip = Int(offset - start)
        let length = ((skip + data.count + sector - 1) / sector) * sector
        var bytes = (skip == 0 && length == data.count) ? data : try read(offset: start, count: length)
        if skip != 0 || length != data.count { bytes.replaceSubrange(skip..<(skip + data.count), with: data) }
        let actual = try bytes.withUnsafeBytes { try resource.write(from: $0, startingAt: off_t(start), length: length) }
        guard actual == length else { throw posix(EIO) }
    }
    public func flush() throws { try resource.metadataFlush() }
}

private func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

@available(macOS 15.4, *)
public final class MacNTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, FSManageableResourceMaintenanceOperations, @unchecked Sendable {
    private var currentResource: FSBlockDeviceResource?
    public override init() { super.init() }
    public func probeResource(resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void) {
        guard let resource = resource as? FSBlockDeviceResource else { reply(.notRecognized, nil); return }
        do {
            currentResource = resource
            let boot = try BootSector(data: FSResourceBlockDevice(resource: resource).read(offset: 0, count: 512))
            reply(.usable(name: "MacNTFS", containerID: FSContainerIdentifier(uuid: Self.identifier(boot.volumeSerialNumber))), nil)
        } catch { reply(.notRecognized, nil) }
    }
    public func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (FSVolume?, Error?) -> Void) {
        guard let resource = resource as? FSBlockDeviceResource else { reply(nil, posix(ENODEV)); return }
        do {
            currentResource = resource
            var device = FSResourceBlockDevice(resource: resource, readOnly: options.taskOptions.contains("--rdonly"))
            var volume = try NTFSVolume(blockDevice: device)
            // Like NTFS-3G-based drivers, fall back to read-only instead of risking a volume
            // that Windows still has to recover (hibernation, Fast Startup, unfinished journal).
            if device.isWritable, let issue = NTFSVolumeWriter.writeSafetyIssue(volume) {
                NSLog("MacNTFS: mounting %@ read-only: %@", volume.volumeName, issue)
                device = FSResourceBlockDevice(resource: resource, readOnly: true)
                volume = try NTFSVolume(blockDevice: device)
            }
            containerStatus = .ready
            reply(MacNTFSFSVolume(coreVolume: volume, resource: resource), nil)
        }
        catch { reply(nil, error) }
    }
    public func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) { currentResource = nil; containerStatus = .notReady(status: posix(ENODEV)); reply(nil) }
    public func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        guard let resource = currentResource else { throw posix(ENODEV) }
        let progress = Progress(totalUnitCount: 1)
        DispatchQueue.global().async {
            do {
                let report = try NTFSVolumeChecker.verify(device: FSResourceBlockDevice(resource: resource, readOnly: true))
                for issue in report.issues { task.logMessage(issue) }
                guard report.isHealthy else { throw posix(EIO) }
                progress.completedUnitCount = 1; task.didComplete(error: nil)
            } catch { task.didComplete(error: error) }
        }
        return progress
    }
    public func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        guard let resource = currentResource else { throw posix(ENODEV) }
        let arguments = options.taskOptions
        var label = "MacNTFS"
        if let index = arguments.firstIndex(of: "-L"), arguments.indices.contains(index + 1) { label = arguments[index + 1] }
        let progress = Progress(totalUnitCount: 1)
        let volumeLabel = label
        DispatchQueue.global().async {
            do {
                try NTFSFormatter.format(device: FSResourceBlockDevice(resource: resource), options: .init(volumeName: volumeLabel))
                progress.completedUnitCount = 1; task.didComplete(error: nil)
            } catch { task.didComplete(error: error) }
        }
        return progress
    }
    fileprivate static func identifier(_ serial: UInt64) -> UUID {
        UUID(uuidString: String(format: "4D41434E-5446-5300-%04llX-%012llX", serial >> 48, serial & 0xFFFFFFFFFFFF))!
    }
}

@available(macOS 15.4, *)
private final class NTFSFSItem: FSItem {
    let recordNumber: UInt64
    var path: String
    init(recordNumber: UInt64, path: String) { self.recordNumber = recordNumber; self.path = path; super.init() }
}

/// All engine operations serialize on one recursive lock, including multi-step metadata mutations.
@available(macOS 15.4, *)
public final class MacNTFSFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, FSVolume.OpenCloseOperations, @unchecked Sendable {
    public let coreVolume: NTFSVolume
    public let resource: FSBlockDeviceResource?
    private let lock = NSRecursiveLock()
    private var items: [UInt64: NTFSFSItem] = [:]
    private var generation: UInt64 = 1
    /// Files whose directory index entries still carry an older size or time.
    private var pendingEntries: Set<UInt64> = []
    private var cachedUsedClusters: UInt64?
    var rootItem: FSItem { lock.lock(); defer { lock.unlock() }; return item(5, path: "/") }
    public init(coreVolume: NTFSVolume, resource: FSBlockDeviceResource? = nil) {
        self.coreVolume = coreVolume; self.resource = resource
        super.init(volumeID: FSVolume.Identifier(uuid: MacNTFSFileSystem.identifier(coreVolume.bootSector.volumeSerialNumber)), volumeName: FSFileName(string: coreVolume.volumeName))
    }
    private func item(_ record: UInt64, path: String) -> NTFSFSItem {
        if let found = items[record] { found.path = path; return found }
        let found = NTFSFSItem(recordNumber: record, path: path); items[record] = found; return found
    }
    private func node(_ item: FSItem) throws -> NTFSFSItem { guard let n = item as? NTFSFSItem else { throw posix(EINVAL) }; return n }
    private func child(_ name: FSFileName, of directory: FSItem) throws -> String {
        guard let name = name.string, !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else { throw posix(EINVAL) }
        let dir = try node(directory)
        return (dir.path == "/" ? "" : dir.path) + "/" + name
    }
    private func attrs(_ node: NTFSFSItem) throws -> FSItem.Attributes {
        let record = try coreVolume.readMFTRecord(number: node.recordNumber)
        let attr = FSItem.Attributes()
        attr.type = record.isDirectory ? .directory : .file
        attr.mode = record.isDirectory ? 0o755 : 0o644
        attr.uid = getuid(); attr.gid = getgid(); attr.linkCount = 1
        attr.fileID = FSItem.Identifier(node.recordNumber == 5 ? 2 : node.recordNumber + 16)
        let parent = record.primaryFileName.map { $0.parentDirectoryRecordNumber } ?? 5
        attr.parentID = FSItem.Identifier(parent == 5 ? 2 : parent + 16)
        if !record.isDirectory {
            let stream = try coreVolume.dataSize(record: record)
            attr.size = stream.size; attr.allocSize = stream.allocated
        }
        if let info = record.standardInformation {
            attr.birthTime = Self.time(info.creationTime); attr.modifyTime = Self.time(info.modificationTime)
            attr.changeTime = Self.time(info.mftModificationTime); attr.accessTime = Self.time(info.accessTime)
        }
        return attr
    }
    private static func time(_ date: Date) -> timespec { let value = date.timeIntervalSince1970; return timespec(tv_sec: Int(value), tv_nsec: Int((value - floor(value)) * 1_000_000_000)) }
    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities(); c.supports64BitObjectIDs = true; c.supportsHiddenFiles = true
        c.doesNotSupportSettingFilePermissions = true; c.doesNotSupportImmutableFiles = true; c.caseFormat = .insensitiveCasePreserving
        return c
    }
    public var volumeStatistics: FSStatFSResult {
        lock.lock(); defer { lock.unlock() }
        let result = FSStatFSResult(fileSystemTypeName: "macntfs")
        result.blockSize = Int(coreVolume.bootSector.clusterSizeBytes); result.ioSize = 65536
        result.totalBlocks = coreVolume.bootSector.totalSizeBytes / UInt64(result.blockSize)
        // Finder polls statistics often; $Bitmap is rescanned only after a change.
        // Unreadable allocation metadata must never be reported as available disk space.
        if cachedUsedClusters == nil, let record = try? coreVolume.readMFTRecord(number: 6),
           let bitmap = try? coreVolume.readData(record: record) {
            cachedUsedClusters = bitmap.reduce(UInt64(0)) { $0 + UInt64($1.nonzeroBitCount) }
        }
        if let used = cachedUsedClusters {
            result.freeBlocks = result.totalBlocks > used ? result.totalBlocks - used : 0
            result.availableBlocks = result.freeBlocks; result.usedBlocks = result.totalBlocks - result.freeBlocks
        }
        return result
    }
    public var maximumLinkCount: Int { 1 }
    public var maximumNameLength: Int { 255 }
    public var restrictsOwnershipChanges: Bool { true }
    public var truncatesLongNames: Bool { false }
    public var maximumFileSizeInBits: Int { 63 }
    public var maximumXattrSizeInBits: Int { 0 }
    public var enableOpenUnlinkEmulation: Bool { true }
    public func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, Error?) -> Void) { lock.lock(); defer { lock.unlock() }; reply(item(5, path: "/"), nil) }
    public func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping (Error?) -> Void) { lock.lock(); defer { lock.unlock() }; let error = syncPendingEntries(); items.removeAll(); reply(error) }
    public func mount(options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) { reply(nil) }
    public func unmount(replyHandler reply: @escaping () -> Void) { lock.lock(); defer { lock.unlock() }; _ = syncPendingEntries(); try? coreVolume.blockDevice.flush(); reply() }
    public func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping (Error?) -> Void) { lock.lock(); defer { lock.unlock() }; if let error = syncPendingEntries() { reply(error); return }; do { try coreVolume.blockDevice.flush(); reply(nil) } catch { reply(error) } }
    public func reclaimItem(_ item: FSItem, replyHandler reply: @escaping (Error?) -> Void) { lock.lock(); defer { lock.unlock() }; var error: Error?; if let item = item as? NTFSFSItem { error = syncPendingEntry(item.recordNumber); items.removeValue(forKey: item.recordNumber) }; reply(error) }
    public func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) { reply(nil) }
    /// Directory index entries are refreshed once the last writer closes, as NTFS-3G does on release.
    public func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping (Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !modes.contains(.write), let node = item as? NTFSFSItem else { reply(nil); return }
        reply(syncPendingEntry(node.recordNumber))
    }
    private func syncPendingEntry(_ record: UInt64) -> Error? {
        guard pendingEntries.contains(record) else { return nil }
        do { try coreVolume.syncDirectoryEntry(recordNumber: record); pendingEntries.remove(record); changed(); return nil }
        catch { return error }
    }
    private func syncPendingEntries() -> Error? {
        var failure: Error?
        for record in pendingEntries.sorted() { if let error = syncPendingEntry(record) { failure = failure ?? error } }
        return failure
    }
    private func changed() { generation &+= 1; cachedUsedClusters = nil }
    public func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            let path = try child(name, of: directory), parent = try node(directory)
            guard let entry = try coreVolume.listDirectory(recordNumber: parent.recordNumber).first(where: { $0.name.compare(name.string ?? "", options: .caseInsensitive) == .orderedSame }) else { throw posix(ENOENT) }
            let parentPath = (path as NSString).deletingLastPathComponent
            reply(item(entry.mftRecordNumber, path: (parentPath == "/" ? "" : parentPath) + "/" + entry.name), FSFileName(string: entry.name), nil)
        } catch { reply(nil, nil, error) }
    }
    public func getAttributes(_ desired: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) { lock.lock(); defer { lock.unlock() }; do { reply(try attrs(node(item)), nil) } catch { reply(nil, error) } }
    public func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            let node = try node(directory)
            var entries = try coreVolume.listDirectory(recordNumber: node.recordNumber).filter { $0.mftRecordNumber >= 16 && $0.name != "." && $0.name != ".." }
            if attributes == nil {
                let parent = try coreVolume.readMFTRecord(number: node.recordNumber).primaryFileName?.parentDirectoryRecordNumber ?? 5
                entries.insert(DirectoryItem(name: "..", mftRecordNumber: parent, isDirectory: true, fileSize: 0, modificationDate: .distantPast, creationDate: .distantPast), at: 0)
                entries.insert(DirectoryItem(name: ".", mftRecordNumber: node.recordNumber, isDirectory: true, fileSize: 0, modificationDate: .distantPast, creationDate: .distantPast), at: 0)
            }
            guard cookie.rawValue <= UInt64(entries.count) else { throw posix(EINVAL) }
            if cookie.rawValue > 0 && verifier.rawValue != generation { throw posix(EINVAL) }
            for index in Int(cookie.rawValue)..<entries.count {
                let entry = entries[index], path = (node.path == "/" ? "" : node.path) + "/" + entry.name
                let id = FSItem.Identifier(entry.mftRecordNumber == 5 ? 2 : entry.mftRecordNumber + 16)
                let attr = attributes == nil ? nil : try attrs(item(entry.mftRecordNumber, path: path))
                if !packer.packEntry(name: FSFileName(string: entry.name), itemType: entry.isDirectory ? .directory : .file, itemID: id, nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)), attributes: attr) { break }
            }
            reply(FSDirectoryVerifier(rawValue: generation), nil)
        } catch { reply(FSDirectoryVerifier(rawValue: generation), error) }
    }
    public func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            guard offset >= 0, length >= 0 else { throw posix(EINVAL) }
            let record = try coreVolume.readMFTRecord(number: node(item).recordNumber)
            let data = try coreVolume.readData(record: record, offset: UInt64(offset), length: length)
            _ = buffer.withUnsafeMutableBytes { raw in data.copyBytes(to: raw) }
            reply(data.count, nil)
        } catch { reply(0, error) }
    }
    public func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents: FSFileName, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) { reply(nil, nil, posix(ENOTSUP)) }
    public func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) { reply(nil, posix(ENOTSUP)) }
    public func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) { reply(nil, posix(ENOTSUP)) }
    // Mutation methods are connected below once the core transaction APIs are available.
    public func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            let path = try child(name, of: directory), parent = try node(directory)
            guard let filename = name.string else { throw posix(EINVAL) }
            if try coreVolume.listDirectory(recordNumber: parent.recordNumber).contains(where: { $0.name.compare(filename, options: .caseInsensitive) == .orderedSame }) { throw posix(EEXIST) }
            let number: UInt64
            switch type {
            case .file: number = try coreVolume.writeFile(fileName: filename, data: Data(), directoryPath: parent.path)
            case .directory: number = try coreVolume.createDirectory(name: filename, directoryPath: parent.path)
            default: throw posix(ENOTSUP)
            }
            changed()
            reply(item(number, path: path), name, nil)
        } catch { reply(nil, nil, error) }
    }
    public func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            _ = try child(name, of: directory)
            try coreVolume.removeItem(name: name.string!, directoryPath: node(directory).path)
            if let removed = item as? NTFSFSItem { pendingEntries.remove(removed.recordNumber) }
            changed(); reply(nil)
        } catch { reply(error) }
    }
    public func renameItem(_ item: FSItem, inDirectory source: FSItem, named name: FSFileName, to newName: FSFileName, inDirectory destination: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            let sourcePath = try child(name, of: source), destinationPath = try child(newName, of: destination)
            try coreVolume.renameItem(sourcePath: sourcePath, destinationPath: destinationPath, replaceExisting: overItem != nil)
            for cached in items.values {
                if cached.path == sourcePath { cached.path = destinationPath }
                else if cached.path.hasPrefix(sourcePath + "/") { cached.path = destinationPath + cached.path.dropFirst(sourcePath.count) }
            }
            changed(); reply(newName, nil)
        } catch { reply(nil, error) }
    }
    public func setAttributes(_ attributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            let n = try node(item)
            let record = try coreVolume.readMFTRecord(number: n.recordNumber)
            if attributes.isValid(.size) && !record.isDirectory {
                try coreVolume.truncate(recordNumber: n.recordNumber, size: attributes.size, updateDirectory: false)
                pendingEntries.insert(n.recordNumber); changed()
                attributes.consumedAttributes.insert(.size)
            }
            if attributes.isValid(.birthTime) || attributes.isValid(.modifyTime) || attributes.isValid(.accessTime) {
                func date(_ time: timespec) -> Date { Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000) }
                try coreVolume.setFileTimes(recordNumber: n.recordNumber,
                    creation: attributes.isValid(.birthTime) ? date(attributes.birthTime) : nil,
                    modification: attributes.isValid(.modifyTime) ? date(attributes.modifyTime) : nil,
                    access: attributes.isValid(.accessTime) ? date(attributes.accessTime) : nil)
                for attribute: FSItem.Attribute in [.birthTime, .modifyTime, .accessTime] where attributes.isValid(attribute) { attributes.consumedAttributes.insert(attribute) }
            }
            reply(try attrs(n), nil)
        } catch { reply(nil, error) }
    }
    public func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            guard offset >= 0 else { throw posix(EINVAL) }
            let record = try node(item).recordNumber
            try coreVolume.writeData(recordNumber: record, offset: UInt64(offset), data: contents, updateDirectory: false)
            pendingEntries.insert(record); cachedUsedClusters = nil
            reply(contents.count, nil)
        } catch { reply(0, error) }
    }
}
#endif
