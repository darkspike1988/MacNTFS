import Foundation

/// An error in the form file system frameworks (FSKit, FUSE) need: a kind and a POSIX error number.
public enum FileSystemError: Error, Equatable, Sendable {
    /// The operation would change the volume. MacNTFS never does.
    case readOnly
    case notFound
    case notADirectory
    case isADirectory
    /// A feature that is refused on purpose (encryption, reparse points, ...). The data is not read.
    case unsupported(String)
    /// The volume is damaged or cannot be read.
    case ioError(String)
    case invalidArgument(String)

    /// The POSIX error number a file system module returns to the system.
    public var posixCode: Int32 {
        switch self {
        case .readOnly: return EROFS
        case .notFound: return ENOENT
        case .notADirectory: return ENOTDIR
        case .isADirectory: return EISDIR
        case .unsupported: return ENOTSUP
        case .ioError: return EIO
        case .invalidArgument: return EINVAL
        }
    }

    public init(_ error: Error) {
        if let known = error as? FileSystemError { self = known; return }
        switch error {
        case NTFSError.pathNotFound, NTFSError.recordNotAllocated: self = .notFound
        case NTFSError.notADirectory: self = .notADirectory
        case NTFSError.isADirectory: self = .isADirectory
        case NTFSError.unsupported(let feature): self = .unsupported(feature.rawValue)
        default: self = .ioError(error.localizedDescription)
        }
    }
}

/// What an item is. Links are reported as links and never followed.
public enum FileSystemItemKind: Sendable, Equatable {
    case file
    case directory
    /// A symbolic link, a junction or a WSL or Interix link. `ReadOnlyFileSystem.readLink` gives the target.
    case symlink
    /// A reparse point that is neither a file nor a link MacNTFS understands (cloud placeholder, deduplicated file).
    case other
}

/// An item of the volume, identified by its MFT record number as file systems expect, not by a path.
public struct FileSystemItem: Sendable, Equatable {
    public let id: UInt64
    /// MFT record number of the directory that holds the item (the root is its own parent).
    public let parentID: UInt64
    public let kind: FileSystemItemKind
    /// Size of the default data stream. Zero for directories.
    public let size: UInt64
    /// The size rounded up to whole clusters. Compressed and sparse files can take less on disk.
    public let allocatedSize: UInt64
    public let linkCount: UInt16
    public let creationDate: Date
    public let modificationDate: Date
    public let changeDate: Date
    public let accessDate: Date
    /// DOS attribute flags: 0x1 read-only, 0x2 hidden, 0x4 system.
    public let dosFlags: UInt32

    public var isHidden: Bool { dosFlags & 0x2 != 0 }
    public var isSystem: Bool { dosFlags & 0x4 != 0 }
}

/// One page of a directory listing.
public struct DirectoryPage: Sendable {
    /// `next` of an entry is the position to pass as `from` to continue directly after it. Entries that cannot be
    /// read are left out, so positions are not the same as array indexes.
    public let items: [(name: String, item: FileSystemItem, next: Int)]
    /// Pass this as `from` to get the next page; nil after the last one.
    public let next: Int?
}

/// A bounded least-recently-used cache. The values are copies of what was read, so the cache cannot change a volume.
final class LRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private let capacity: Int
    private var storage = [Key: Value]()
    private var order = [Key]()
    private let lock = NSLock()

    init(capacity: Int) { self.capacity = max(0, capacity) }

    func value(for key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let value = storage[key] else { return nil }
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
        return value
    }

    func insert(_ value: Value, for key: Key) {
        guard capacity > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if storage[key] != nil, let index = order.lastIndex(of: key) { order.remove(at: index) }
        storage[key] = value
        order.append(key)
        while order.count > capacity { storage[order.removeFirst()] = nil }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll(); order.removeAll()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }
}

/// The read operations of a file system module on top of `NTFSVolume`, with the write operations present
/// and always refused. A framework adapter (FSKit) only has to map its calls to these methods and the errors
/// to `FileSystemError.posixCode`.
///
/// Records and directory listings are cached (bounded). The cache assumes that nobody changes the volume while
/// it is in use. That is why the command line tool refuses a device that another driver has mounted for writing;
/// a module that mounts a volume read-only has the volume to itself. Call `purgeCaches()` if that can change.
public final class ReadOnlyFileSystem: @unchecked Sendable {
    public struct Options: Sendable {
        public var recordCacheCapacity = 4096
        public var directoryCacheCapacity = 8
        /// Hide the NTFS metadata files (`$MFT`, `$Bitmap`, ...) in the root directory.
        public var hidesMetadataFiles = true
        public init() {}
    }

    public static let rootID: UInt64 = 5
    /// Records below this number are metadata files, except the root directory.
    static let firstUserRecord: UInt64 = 24

    public let volume: NTFSVolume
    public let options: Options
    private let records: LRUCache<UInt64, MFTRecord>
    private let listings: LRUCache<UInt64, [DirectoryItem]>

    public init(volume: NTFSVolume, options: Options = Options()) {
        self.volume = volume
        self.options = options
        self.records = LRUCache(capacity: options.recordCacheCapacity)
        self.listings = LRUCache(capacity: options.directoryCacheCapacity)
    }

    /// Number of records currently cached (for tests and diagnostics).
    public var cachedRecordCount: Int { records.count }

    public func purgeCaches() {
        records.removeAll()
        listings.removeAll()
    }

    // MARK: Reading

    public func item(id: UInt64) throws -> FileSystemItem {
        try describe(try record(id))
    }

    public func lookup(name: String, inDirectory directory: UInt64) throws -> FileSystemItem {
        let parent = try record(directory)
        guard parent.isDirectory else { throw FileSystemError.notADirectory }
        var lastError: Error = FileSystemError.notFound
        for candidate in Self.nameCandidates(name) {
            do {
                let child = try volume.child(named: candidate, in: parent, path: candidate)
                records.insert(child, for: child.recordNumber)
                if options.hidesMetadataFiles, child.recordNumber < Self.firstUserRecord, child.recordNumber != Self.rootID {
                    throw FileSystemError.notFound
                }
                return try describe(child)
            } catch {
                lastError = error
                // Only a missing name is worth another spelling; any other error is final.
                if case NTFSError.pathNotFound = error { continue }
                if let known = error as? FileSystemError, known == .notFound { continue }
                throw FileSystemError(error)
            }
        }
        throw FileSystemError(lastError)
    }

    /// The spellings to try for a name: as given, then composed (NFC, how Windows writes most names),
    /// then decomposed (NFD, how macOS often sends them). NTFS compares UTF-16 code units, not Unicode text.
    static func nameCandidates(_ name: String) -> [String] {
        var result = [name]
        for variant in [name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping]
        where !result.contains(where: { Array($0.utf8) == Array(variant.utf8) }) {
            result.append(variant)
        }
        return result
    }

    /// A page of a directory. `from` is the position to continue at, starting with 0.
    public func contents(ofDirectory directory: UInt64, from: Int = 0, count: Int = 128) throws -> DirectoryPage {
        guard from >= 0, count > 0 else { throw FileSystemError.invalidArgument("from and count must be positive") }
        let parent = try record(directory)
        guard parent.isDirectory else { throw FileSystemError.notADirectory }
        let all: [DirectoryItem]
        if let cached = listings.value(for: directory) {
            all = cached
        } else {
            do {
                var listed = try volume.listDirectory(recordNumber: directory)
                if options.hidesMetadataFiles {
                    listed = listed.filter { $0.mftRecordNumber >= Self.firstUserRecord || $0.mftRecordNumber == Self.rootID }
                }
                all = listed
            } catch {
                throw FileSystemError(error)
            }
            listings.insert(all, for: directory)
        }
        let end = min(all.count, from + count)
        let slice = from < all.count ? all[from..<end] : []
        var items = [(name: String, item: FileSystemItem, next: Int)]()
        for (offset, entry) in slice.enumerated() {
            do {
                items.append((entry.name, try describe(try record(entry.mftRecordNumber)), from + offset + 1))
            } catch {
                // A stale or damaged entry is left out of the listing; a lookup of it reports the error.
                continue
            }
        }
        return DirectoryPage(items: items, next: end < all.count ? end : nil)
    }

    /// File content. `stream` names an alternate data stream; nil is the default stream.
    public func read(id: UInt64, stream: String? = nil, offset: UInt64, length: Int) throws -> Data {
        let target = try record(id)
        if stream == nil {
            if target.attribute(ofType: .reparsePoint) != nil { throw FileSystemError.unsupported("reparse") }
            if target.isDirectory { throw FileSystemError.isADirectory }
        }
        do {
            return try volume.readData(record: target, stream: stream, offset: offset, length: length)
        } catch {
            throw FileSystemError(error)
        }
    }

    /// Where a link points, or nil if the item is not a link.
    public func readLink(id: UInt64) throws -> LinkInfo? {
        do {
            return try volume.linkInfo(of: try record(id))
        } catch {
            throw FileSystemError(error)
        }
    }

    /// The names of the alternate data streams of an item.
    public func streamNames(id: UInt64) throws -> [String] {
        try record(id).dataStreams.compactMap { stream in
            guard let name = stream.name, !name.isEmpty else { return nil }
            return name
        }
    }

    // MARK: Writing is not possible

    public func write(id: UInt64, offset: UInt64, data: Data) throws -> Never { throw FileSystemError.readOnly }
    public func setSize(id: UInt64, size: UInt64) throws -> Never { throw FileSystemError.readOnly }
    public func createItem(named name: String, inDirectory directory: UInt64, kind: FileSystemItemKind) throws -> Never {
        throw FileSystemError.readOnly
    }
    public func removeItem(named name: String, inDirectory directory: UInt64) throws -> Never { throw FileSystemError.readOnly }
    public func renameItem(named name: String, inDirectory directory: UInt64, to newName: String, inDirectory newDirectory: UInt64) throws -> Never {
        throw FileSystemError.readOnly
    }

    // MARK: Helpers

    private func record(_ id: UInt64) throws -> MFTRecord {
        if let cached = records.value(for: id) { return cached }
        do {
            let fresh = try volume.readMFTRecord(number: id)
            guard fresh.isInUse else { throw FileSystemError.notFound }
            records.insert(fresh, for: id)
            return fresh
        } catch {
            throw FileSystemError(error)
        }
    }

    private func describe(_ record: MFTRecord) throws -> FileSystemItem {
        let info = record.standardInformation
        let now = Date(timeIntervalSince1970: 0)
        let kind: FileSystemItemKind
        if record.attribute(ofType: .reparsePoint) != nil {
            switch try? volume.linkInfo(of: record)?.kind {
            case .symlink, .junction, .wslSymlink, .interixSymlink: kind = .symlink
            default: kind = .other
            }
        } else if record.isDirectory {
            kind = .directory
        } else if (info?.dosFlags ?? 0) & 0x4 != 0, (try? volume.linkInfo(of: record)) != nil {
            kind = .symlink
        } else {
            kind = .file
        }
        let size: UInt64 = record.isDirectory ? 0 : (record.defaultDataAttribute?.realDataSize ?? 0)
        let cluster = UInt64(volume.bootSector.clusterSizeBytes)
        let (rounded, overflow) = size.addingReportingOverflow(cluster - 1)
        let allocated = overflow ? size : rounded / cluster * cluster
        return FileSystemItem(
            id: record.recordNumber,
            parentID: record.recordNumber == Self.rootID ? Self.rootID : (record.primaryFileName?.parentDirectoryRecordNumber ?? Self.rootID),
            kind: kind,
            size: size,
            allocatedSize: allocated,
            linkCount: record.header.hardLinkCount,
            creationDate: info?.creationTime ?? now,
            modificationDate: info?.modificationTime ?? now,
            changeDate: info?.mftModificationTime ?? now,
            accessDate: info?.accessTime ?? now,
            dosFlags: info?.dosFlags ?? 0
        )
    }
}
