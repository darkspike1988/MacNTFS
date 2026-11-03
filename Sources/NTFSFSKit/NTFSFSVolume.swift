#if canImport(FSKit)
import Foundation
import FSKit
import NTFSCore

/// An item of the volume as FSKit holds it: the MFT record number.
@available(macOS 27.0, *)
final class NTFSItem: FSItem {
    let id: UInt64
    init(id: UInt64) {
        self.id = id
        super.init()
    }
}

/// The NTFS volume for FSKit. Every operation that reads goes to `ReadOnlyFileSystem`; every operation that
/// would write answers `EROFS` without touching the engine.
@available(macOS 27.0, *)
final class NTFSFSVolume: FSVolume, FSVolume.Handler, FSVolume.ReadWriteHandler {
    private let fileSystem: ReadOnlyFileSystem
    // The read call has no FSContext. The owner is the user whose request was seen last (the one who mounted).
    private let ownerLock = NSLock()
    private var owner: (uid: UInt32, gid: UInt32) = (getuid(), getgid())

    init(fileSystem: ReadOnlyFileSystem, volumeID: FSVolume.Identifier, name: FSFileName) {
        self.fileSystem = fileSystem
        super.init(volumeID: volumeID, volumeName: name)
    }

    // MARK: Item identifiers

    /// FSKit reserves 0 to 2; NTFS keeps its own metadata in records 0 to 23 and the root in record 5.
    static func itemID(_ record: UInt64) -> FSItem.Identifier {
        record == ReadOnlyFileSystem.rootID ? .rootDirectory : FSItem.Identifier(record)
    }

    static func parentItemID(_ item: FileSystemItem) -> FSItem.Identifier {
        item.id == ReadOnlyFileSystem.rootID ? .parentOfRoot : itemID(item.parentID)
    }

    private func recordNumber(of item: FSItem) throws -> UInt64 {
        guard let item = item as? NTFSItem else { throw posixError(EINVAL) }
        return item.id
    }

    private static func timespec(_ date: Date) -> timespec {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        return Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000))
    }

    private static func itemType(_ kind: FileSystemItemKind) -> FSItem.ItemType {
        switch kind {
        case .directory: return .directory
        case .symlink: return .symlink
        case .file, .other: return .file
        }
    }

    /// The attributes FSKit asks for. A read-only volume owned by the user who mounted it.
    func attributes(of item: FileSystemItem, context: FSContext) -> FSItem.Attributes {
        let uid = UInt32(truncatingIfNeeded: context.effectiveUserID)
        let gid = UInt32(truncatingIfNeeded: context.effectiveGroupID)
        ownerLock.lock(); owner = (uid, gid); ownerLock.unlock()
        return attributes(of: item, uid: uid, gid: gid)
    }

    func attributes(of item: FileSystemItem, uid: UInt32, gid: UInt32) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        attributes.type = Self.itemType(item.kind)
        attributes.mode = item.kind == .directory ? 0o555 : (item.kind == .symlink ? 0o755 : 0o444)
        attributes.uid = uid
        attributes.gid = gid
        attributes.linkCount = UInt32(item.linkCount)
        attributes.flags = item.isHidden ? UInt32(UF_HIDDEN) : 0
        attributes.size = item.size
        attributes.allocSize = item.allocatedSize
        attributes.fileID = Self.itemID(item.id)
        attributes.parentID = Self.parentItemID(item)
        attributes.birthTime = Self.timespec(item.creationDate)
        attributes.modifyTime = Self.timespec(item.modificationDate)
        attributes.changeTime = Self.timespec(item.changeDate)
        attributes.accessTime = Self.timespec(item.accessDate)
        return attributes
    }

    // MARK: Capabilities and limits

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supports64BitObjectIDs = true
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsHardLinks = true
        capabilities.supportsSparseFiles = true
        capabilities.supports2TBFiles = true
        capabilities.supportsHiddenFiles = true
        capabilities.doesNotSupportSettingFilePermissions = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let boot = fileSystem.volume.bootSector
        let clusterSize = UInt64(boot.clusterSizeBytes)
        let clusters = boot.totalSizeBytes / max(1, clusterSize)
        let result = FSStatFSResult(fileSystemTypeName: "ntfs")
        result.blockSize = Int(clusterSize)
        result.ioSize = Int(clusterSize)
        result.totalBlocks = clusters
        result.usedBlocks = clusters   // free space is not read; the volume is read-only
        result.freeBlocks = 0
        result.availableBlocks = 0
        result.totalBytes = boot.totalSizeBytes
        result.usedBytes = boot.totalSizeBytes
        result.freeBytes = 0
        result.availableBytes = 0
        return result
    }

    var maximumLinkCount: Int { 1023 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64.max >> 1 }

    // MARK: Life cycle

    func activateVolume(options: FSTaskOptions, replyHandler reply: @escaping (FSActivateResult?, (any Error)?) -> Void) {
        reply(FSActivateResult(rootItem: NTFSItem(id: ReadOnlyFileSystem.rootID)), nil)
    }

    func deactivateVolume(options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        fileSystem.purgeCaches()
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func unmount(replyHandler reply: @escaping () -> Void) { reply() }
    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) { reply(nil) }
    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) { reply(nil) }

    // MARK: Reading

    func lookupItem(named name: FSFileName, in directory: FSItem, context: FSContext,
                    replyHandler reply: @escaping (FSLookupItemResult?, (any Error)?) -> Void) {
        do {
            guard let text = name.string else { throw FileSystemError.notFound }
            let found = try fileSystem.lookup(name: text, inDirectory: try recordNumber(of: directory))
            reply(FSLookupItemResult(foundItem: NTFSItem(id: found.id), itemName: name,
                                     itemAttributes: attributes(of: found, context: context)), nil)
        } catch {
            reply(nil, Self.nsError(error))
        }
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, context: FSContext,
                       replyHandler reply: @escaping (FSGetAttributesResult?, (any Error)?) -> Void) {
        do {
            let described = try fileSystem.item(id: try recordNumber(of: item))
            reply(FSGetAttributesResult(attributes: attributes(of: described, context: context)), nil)
        } catch {
            reply(nil, Self.nsError(error))
        }
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
                            attributes request: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, context: FSContext,
                            replyHandler reply: @escaping (FSEnumerateDirectoryResult?, (any Error)?) -> Void) {
        // The directory never changes while it is mounted, so the verifier is a constant (it must not be zero).
        let result = FSEnumerateDirectoryResult(verifier: 1)
        do {
            let id = try recordNumber(of: directory)
            let this = try fileSystem.item(id: id)
            let wantsAttributes = request != nil

            // Cookie 0 starts the listing, 1 follows ".", and 2 + n follows the entry at position n - 1.
            var position = cookie.rawValue
            if position == 0 {
                guard packer.packEntry(name: FSFileName(string: "."), itemType: .directory, itemID: Self.itemID(this.id),
                                       nextCookie: FSDirectoryCookie(rawValue: 1),
                                       attributes: wantsAttributes ? attributes(of: this, context: context) : nil) else {
                    reply(result, nil); return
                }
                position = 1
            }
            if position == 1 {
                let parent = try fileSystem.item(id: this.parentID)
                guard packer.packEntry(name: FSFileName(string: ".."), itemType: .directory, itemID: Self.itemID(parent.id),
                                       nextCookie: FSDirectoryCookie(rawValue: 2),
                                       attributes: wantsAttributes ? attributes(of: parent, context: context) : nil) else {
                    reply(result, nil); return
                }
                position = 2
            }

            var from = Int(position - 2)
            while true {
                let page = try fileSystem.contents(ofDirectory: id, from: from, count: 64)
                for entry in page.items {
                    let packed = packer.packEntry(
                        name: FSFileName(string: entry.name),
                        itemType: Self.itemType(entry.item.kind),
                        itemID: Self.itemID(entry.item.id),
                        nextCookie: FSDirectoryCookie(rawValue: UInt64(entry.next) + 2),
                        attributes: wantsAttributes ? attributes(of: entry.item, context: context) : nil
                    )
                    if !packed { reply(result, nil); return }   // the buffer is full; FSKit calls again with the cookie
                }
                guard let next = page.next else { break }
                from = next
            }
            reply(result, nil)
        } catch {
            reply(nil, Self.nsError(error))
        }
    }

    func readSymbolicLink(_ item: FSItem, context: FSContext,
                          replyHandler reply: @escaping (FSReadSymlinkResult?, (any Error)?) -> Void) {
        do {
            let id = try recordNumber(of: item)
            guard let link = try fileSystem.readLink(id: id) else { throw FileSystemError.invalidArgument("not a link") }
            reply(FSReadSymlinkResult(contents: FSFileName(string: link.posixTarget),
                                      symlinkAttributes: attributes(of: try fileSystem.item(id: id), context: context)), nil)
        } catch {
            reply(nil, Self.nsError(error))
        }
    }

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (FSReadFileResult?, (any Error)?) -> Void) {
        do {
            let id = try recordNumber(of: item)
            guard offset >= 0, length >= 0 else { throw FileSystemError.invalidArgument("negative offset or length") }
            let data = try fileSystem.read(id: id, offset: UInt64(offset), length: length)
            let copied = buffer.withUnsafeMutableBytes { raw -> Int in
                let count = min(raw.count, data.count)
                data.copyBytes(to: raw.bindMemory(to: UInt8.self).baseAddress!, count: count)
                return count
            }
            ownerLock.lock(); let known = owner; ownerLock.unlock()
            reply(FSReadFileResult(bytesRead: copied,
                                   itemAttributes: attributes(of: try fileSystem.item(id: id), uid: known.uid, gid: known.gid)), nil)
        } catch {
            reply(nil, Self.nsError(error))
        }
    }

    // MARK: Writing is not possible

    func createItem(named name: FSFileName, type: FSItem.ItemType, in directory: FSItem, attributes: FSItem.SetAttributesRequest,
                    context: FSContext, replyHandler reply: @escaping (FSCreateItemResult?, (any Error)?) -> Void) {
        reply(nil, posixError(EROFS))
    }

    func createSymbolicLink(named name: FSFileName, in directory: FSItem, attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName, context: FSContext,
                            replyHandler reply: @escaping (FSCreateSymlinkResult?, (any Error)?) -> Void) {
        reply(nil, posixError(EROFS))
    }

    func createLink(to item: FSItem, named name: FSFileName, in directory: FSItem, context: FSContext,
                    replyHandler reply: @escaping (FSCreateLinkResult?, (any Error)?) -> Void) {
        reply(nil, posixError(EROFS))
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem, overItem: FSItem?, context: FSContext,
                    replyHandler reply: @escaping (FSRenameItemResult?, (any Error)?) -> Void) {
        reply(nil, posixError(EROFS))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, from directory: FSItem, context: FSContext,
                    replyHandler reply: @escaping (FSRemoveItemResult?, (any Error)?) -> Void) {
        reply(nil, posixError(EROFS))
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, context: FSContext,
                       replyHandler reply: @escaping (FSSetAttributesResult?, (any Error)?) -> Void) {
        reply(nil, posixError(EROFS))
    }

    func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler reply: @escaping (FSWriteFileResult?, (any Error)?) -> Void) {
        reply(nil, posixError(EROFS))
    }

    private static func nsError(_ error: Error) -> NSError {
        let bridged = error as NSError
        if bridged.domain == NSPOSIXErrorDomain { return bridged }
        return FileSystemError(error).nsError
    }
}
#endif
