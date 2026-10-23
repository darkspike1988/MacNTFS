import Foundation

extension NTFSVolume {
    public func createDirectory(name: String, directoryPath: String = "/") throws -> UInt64 {
        let parent = try lookup(path: directoryPath)
        guard parent.isDirectory else { throw NTFSError.notADirectory(directoryPath) }
        return try NTFSVolumeWriter.writeFile(volume: self, directoryRecordNumber: parent.record.recordNumber,
                                             fileName: name, data: Data(), isDirectory: true)
    }

    /// With `updateDirectory` false, the parent index keeps the previous size and times
    /// until `syncDirectoryEntry` runs; a file system calls it when the file closes.
    public func writeData(recordNumber: UInt64, offset: UInt64, data: Data, updateDirectory: Bool = true) throws {
        try NTFSVolumeWriter.changeData(volume: self, recordNumber: recordNumber, offset: offset, data: data,
                                        updateDirectory: updateDirectory)
    }

    public func truncate(recordNumber: UInt64, size: UInt64, updateDirectory: Bool = true) throws {
        try NTFSVolumeWriter.changeData(volume: self, recordNumber: recordNumber, size: size,
                                        updateDirectory: updateDirectory)
    }

    public func syncDirectoryEntry(recordNumber: UInt64) throws {
        try NTFSVolumeWriter.syncDirectoryEntry(volume: self, recordNumber: recordNumber)
    }

    public func removeItem(name: String, directoryPath: String = "/") throws {
        try NTFSVolumeWriter.removeItem(volume: self, name: name, directoryPath: directoryPath)
    }

    public func renameItem(sourcePath: String, destinationPath: String, replaceExisting: Bool = false) throws {
        try NTFSVolumeWriter.renameItem(volume: self, sourcePath: sourcePath,
                                       destinationPath: destinationPath, replaceExisting: replaceExisting)
    }

    public func setFileTimes(recordNumber: UInt64, creation: Date? = nil,
                             modification: Date? = nil, access: Date? = nil) throws {
        try NTFSVolumeWriter.setFileTimes(volume: self, recordNumber: recordNumber,
                                         creation: creation, modification: modification, access: access)
    }
}

extension NTFSVolumeWriter {
    /// All metadata plans are validated and saved in memory before the first write.
    /// This provides failure rollback, while on-disk log replay remains a separate concern.
    internal final class MutationContext {
        let volume: NTFSVolume
        let cluster: UInt64
        let clusterAttribute: NTFSAttribute
        let transaction: WriteTransaction
        private var clusterBitmap: BitmapManager?
        var records: BitmapManager?
        var recordBitmapAttribute: NTFSAttribute?

        init(_ original: NTFSVolume) throws {
            volume = try NTFSVolume(blockDevice: original.blockDevice)
            guard volume.bootSector.bytesPerSector == 512, volume.bootSector.mftRecordSizeBytes == 1024 else {
                throw NTFSError.unsupportedFeature("Unsupported writable record geometry")
            }
            try prepareForWriting(volume)
            cluster = UInt64(volume.bootSector.clusterSizeBytes)
            let bitmap = try volume.readMFTRecord(number: 6)
            guard let attr = bitmap.defaultDataAttribute else {
                throw NTFSError.attributeNotFound(type: 0x80, name: nil)
            }
            clusterAttribute = attr
            transaction = WriteTransaction(device: volume.blockDevice)
        }

        /// $Bitmap is loaded only by changes that allocate or free clusters.
        func withClusters<T>(_ body: (inout BitmapManager) throws -> T) throws -> T {
            if clusterBitmap == nil { clusterBitmap = BitmapManager(data: try streamData(clusterAttribute, volume: volume)) }
            return try body(&clusterBitmap!)
        }

        func editableRecord(_ number: UInt64) throws -> MFTRecord {
            guard number >= 24 else { throw POSIXError(.EPERM) }
            let record = try volume.readMFTRecord(number: number)
            guard record.isInUse, record.header.magic == "FILE" else {
                throw NTFSError.recordNotAllocated(recordNumber: number)
            }
            guard record.attribute(ofType: .attributeList) == nil, record.header.hardLinkCount == 1 else {
                throw NTFSError.unsupportedFeature("Mutation of attribute extension records or multiple hard links")
            }
            return record
        }

        func fixed(_ record: MFTRecord) throws -> Data {
            try fixedRecord(readRuns(volume.mftRecordRuns, offset: record.recordNumber * 1024,
                                     count: 1024, cluster: cluster, device: volume.blockDevice),
                            boot: volume.bootSector)
        }

        func stageRecord(_ number: UInt64, _ raw: Data) throws {
            try stageMFTRecord(number, data: raw, runs: volume.mftRecordRuns, volume: volume, tx: transaction)
        }

        func allocateClusters(_ count: Int, near hint: UInt64 = 0) throws -> [DataRun] {
            let limit = volume.bootSector.totalSectors / UInt64(volume.bootSector.sectorsPerCluster)
            return try withClusters { try allocate(count: count, bitmap: &$0, limit: limit, near: hint) }
        }

        func release(_ attr: NTFSAttribute) throws {
            guard attr.flags.isEmpty else { throw NTFSError.unsupportedFeature("Encoded stream mutation") }
            try releaseRuns(attr.runs ?? [])
        }

        func releaseRuns(_ runs: [DataRun]) throws {
            let limit = volume.bootSector.totalSectors / UInt64(volume.bootSector.sectorsPerCluster)
            for run in runs {
                guard let lcn = run.startingLCN, lcn < limit, run.clusterCount <= limit - lcn else {
                    throw NTFSError.corruptRunlist("Invalid stream allocation")
                }
                try withClusters { bits in
                    for bit in lcn..<(lcn + run.clusterCount) { try bits.setAllocated(at: Int(bit), isAllocated: false) }
                }
            }
        }

        func freeRecord(_ record: MFTRecord) throws {
            for attr in record.attributes { try release(attr) }
            if records == nil {
                let mft = try volume.readMFTRecord(number: 0)
                guard let bitmap = mft.attribute(ofType: .bitmap) else {
                    throw NTFSError.attributeNotFound(type: 0xb0, name: nil)
                }
                recordBitmapAttribute = bitmap
                records = BitmapManager(data: try streamData(bitmap, volume: volume))
            }
            try records!.setAllocated(at: Int(record.recordNumber), isAllocated: false)
            var raw = try fixed(record)
            put(UInt16(0), into: &raw, at: 22)
            put(UInt16(0), into: &raw, at: 18)
            let nextSequence = record.header.sequenceNumber == UInt16.max ? 1 : record.header.sequenceNumber + 1
            put(nextSequence, into: &raw, at: 16)
            try stageRecord(record.recordNumber, sealRecord(raw, boot: volume.bootSector))
        }

        func commit() throws {
            if let clusterBitmap {
                try stageBitmap(clusterAttribute, recordNumber: 6, bitmap: clusterBitmap, volume: volume, tx: transaction)
            }
            if let bitmap = recordBitmapAttribute, let records {
                try stageBitmap(bitmap, recordNumber: 0, bitmap: records, volume: volume, tx: transaction)
            }
            try transaction.commit()
        }
    }

    internal static func planDirectory(_ record: MFTRecord, entries originalEntries: [Data],
                                       context ctx: MutationContext) throws {
        guard record.isDirectory, record.attribute(ofType: .attributeList) == nil else {
            throw NTFSError.unsupportedFeature("Unsupported directory record")
        }
        let upcase = try loadUpcase(volume: ctx.volume)
        let pairs = try originalEntries.map { ($0, try collationKey(entryName($0), upcase: upcase)) }
        let entries = pairs.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
        let fixed = try ctx.fixed(record)
        let retained = try attributeParts(fixed).filter {
            let attr = try NTFSAttribute(data: $0, offset: 0)
            return !(attr.name == "$I30" && [.indexRoot, .indexAllocation, .bitmap].contains(attr.type))
        }
        guard let root = record.attribute(ofType: .indexRoot, name: "$I30"),
              let header = root.residentData, header.count >= 32,
              u32(header, 0) == 0x30, u32(header, 4) == 1 else {
            throw NTFSError.corruptDirectoryIndex("Missing filename index")
        }
        var nextID = record.header.nextAttributeID
        func identifier(_ type: AttributeType) throws -> UInt16 {
            if let attr = record.attribute(ofType: type, name: "$I30") { return attr.attributeID }
            guard nextID < UInt16.max else { throw NTFSError.unsupportedFeature("Attribute IDs exhausted") }
            defer { nextID += 1 }
            return nextID
        }
        var attributes = [resident(type: 0x90, name: "$I30",
                                   value: indexRoot(header: header, entries: entries, lastChild: nil),
                                   id: root.attributeID)]
        if !recordFits(fixed, attributes: retained + attributes) {
            let size = Int(u32(header, 8))
            guard size >= 1024, size <= 65536, size.nonzeroBitCount == 1 else {
                throw NTFSError.corruptDirectoryIndex("Invalid index block geometry")
            }
            let tree = try buildIndexTree(entries: entries, blockSize: size, clusterSize: Int(ctx.cluster))
            let runs = try ctx.allocateClusters((tree.data.count + Int(ctx.cluster) - 1) / Int(ctx.cluster))
            var bits = Data(repeating: 0, count: max(8, ((tree.blockCount + 63) / 64) * 8))
            for i in 0..<tree.blockCount { bits[i / 8] |= UInt8(1 << (i % 8)) }
            attributes = [
                resident(type: 0x90, name: "$I30", value: indexRoot(header: header, entries: [], lastChild: tree.rootVCN), id: root.attributeID),
                nonResident(type: 0xa0, name: "$I30", runs: runs, realSize: UInt64(tree.data.count), cluster: ctx.cluster, id: try identifier(.indexAllocation)),
                resident(type: 0xb0, name: "$I30", value: bits, id: try identifier(.bitmap))
            ]
            try stageRuns(runs, offset: 0, data: tree.data, cluster: ctx.cluster, tx: ctx.transaction)
        }
        let rebuilt = try rebuildRecord(fixed, attributes: retained + attributes, nextID: nextID, boot: ctx.volume.bootSector)
        if let old = record.attribute(ofType: .indexAllocation, name: "$I30") { try ctx.release(old) }
        try ctx.stageRecord(record.recordNumber, rebuilt)
    }

    internal static func changeData(volume original: NTFSVolume, recordNumber: UInt64,
                                    offset: UInt64 = 0, data: Data = Data(), size: UInt64? = nil,
                                    updateDirectory: Bool = true) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard offset <= UInt64(Int.max), UInt64(data.count) <= UInt64(Int.max) - offset,
              (size ?? 0) <= UInt64(Int.max) else {
            throw POSIXError(.EFBIG)
        }
        let fast = try MutationContext(original)
        let current = try fast.editableRecord(recordNumber)
        guard !current.isDirectory else { throw POSIXError(.EISDIR) }
        guard let stream = current.defaultDataAttribute, stream.flags.isEmpty else {
            throw NTFSError.unsupportedFeature("Missing or encoded data stream")
        }
        if var sealed = try planStreamInPlace(fast, record: current, offset: offset, data: data, size: size) {
            if updateDirectory { sealed = try refreshFileNames(sealed, boot: fast.volume.bootSector) }
            try fast.stageRecord(recordNumber, sealed)
            if updateDirectory {
                try updateParentKeys(record: MFTRecord(recordNumber: recordNumber, rawData: sealed), context: fast)
            }
            try fast.commit()
            return
        }
        // The in-place plan may have reserved clusters; start over from disk state.
        let ctx = try MutationContext(original)
        let record = try ctx.editableRecord(recordNumber)
        guard let old = record.defaultDataAttribute else {
            throw NTFSError.unsupportedFeature("Missing or encoded data stream")
        }
        let finalSize = size ?? max(old.realDataSize, offset + UInt64(data.count))
        guard finalSize <= UInt64(Int.max) else { throw POSIXError(.EFBIG) }
        var bytes = try ctx.volume.readData(record: record, length: Int(min(finalSize, old.realDataSize)))
        if bytes.count < Int(finalSize) { bytes.append(Data(repeating: 0, count: Int(finalSize) - bytes.count)) }
        if !data.isEmpty {
            guard offset + UInt64(data.count) <= finalSize else { throw POSIXError(.EINVAL) }
            bytes.replaceSubrange(Int(offset)..<(Int(offset) + data.count), with: data)
        }
        var fixed = try ctx.fixed(record)
        var parts = try attributeParts(fixed)
        let originalParts = parts
        let now = FileTimeConverter.toFileTime(date: Date())
        func withData(_ attr: Data, allocated: UInt64) throws -> [Data] {
            try originalParts.compactMap { part in
                let parsed = try NTFSAttribute(data: part, offset: 0)
                if parsed.type == .data && parsed.name == nil { return attr }
                var copy = part
                if parsed.type == .fileName {
                    let start = Int(u16(copy, 20))
                    put(allocated, into: &copy, at: start + 40)
                    put(finalSize, into: &copy, at: start + 48)
                    put(now, into: &copy, at: start + 16)
                    put(now, into: &copy, at: start + 24)
                }
                if parsed.type == .standardInformation {
                    let start = Int(u16(copy, 20))
                    put(now, into: &copy, at: start + 8)
                    put(now, into: &copy, at: start + 16)
                }
                return copy
            }
        }
        let residentData = resident(type: 0x80, name: nil, value: bytes, id: old.attributeID)
        parts = try withData(residentData, allocated: 0)
        if !recordFits(fixed, attributes: parts) {
            let runs = try ctx.allocateClusters((bytes.count + Int(ctx.cluster) - 1) / Int(ctx.cluster))
            let attr = nonResident(type: 0x80, name: nil, runs: runs, realSize: finalSize,
                                   cluster: ctx.cluster, id: old.attributeID)
            parts = try withData(attr, allocated: runs.reduce(UInt64(0)) { $0 + $1.clusterCount * ctx.cluster })
            try stageRuns(runs, offset: 0, data: bytes, cluster: ctx.cluster, tx: ctx.transaction)
        }
        fixed = try rebuildRecord(fixed, attributes: parts, nextID: record.header.nextAttributeID, boot: ctx.volume.bootSector)
        let updated = try MFTRecord(recordNumber: recordNumber, rawData: fixed)
        try ctx.release(old)
        try ctx.stageRecord(recordNumber, fixed)
        try updateParentKeys(record: updated, context: ctx)
        try ctx.commit()
    }

    internal static func updateParentKeys(record: MFTRecord, context ctx: MutationContext) throws {
        let names = record.allAttributes(ofType: .fileName)
        let parents = try Set(names.map { try FileNameAttribute(data: $0.residentData ?? Data()).parentDirectoryRecordNumber })
        for parentNumber in parents {
            let parent = try ctx.volume.readMFTRecord(number: parentNumber)
            let original = try readIndexEntries(volume: ctx.volume, parent: parent)
            var entries: [Data] = []
            for entry in original where u64(entry, 0) & 0x0000ffffffffffff != record.recordNumber { entries.append(entry) }
            for attr in names {
                guard let key = attr.residentData else { throw NTFSError.invalidIndexEntry }
                let name = try FileNameAttribute(data: key)
                if name.parentDirectoryRecordNumber == parentNumber {
                    entries.append(indexEntry(reference: record.recordNumber | UInt64(record.header.sequenceNumber) << 48, key: key))
                }
            }
            try planDirectory(parent, entries: entries, context: ctx)
        }
    }

    internal static func removeItem(volume original: NTFSVolume, name: String, directoryPath: String) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let ctx = try MutationContext(original)
        let parent = try ctx.volume.lookup(path: directoryPath)
        guard parent.isDirectory else { throw NTFSError.notADirectory(directoryPath) }
        let targetPath = directoryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw POSIXError(.EINVAL) }
        let target = try ctx.volume.lookup(path: "/" + (targetPath.isEmpty ? "" : targetPath + "/") + name)
        let record = try ctx.editableRecord(target.record.recordNumber)
        if record.isDirectory, try !ctx.volume.listDirectory(recordNumber: record.recordNumber).isEmpty { throw POSIXError(.ENOTEMPTY) }
        let entries = try readIndexEntries(volume: ctx.volume, parent: parent.record)
            .filter { u64($0, 0) & 0x0000ffffffffffff != record.recordNumber }
        try planDirectory(parent.record, entries: entries, context: ctx)
        try ctx.freeRecord(record)
        try ctx.commit()
    }

    internal static func splitItemPath(_ path: String) throws -> (parent: String, name: String) {
        var parts = path.split(separator: "/").map(String.init)
        guard let name = parts.popLast(), name != ".", name != "..",
              !parts.contains("."), !parts.contains(".."), sanitizeFileName(name) == name,
              name.utf16.count <= 255 else { throw POSIXError(.EINVAL) }
        return ("/" + parts.joined(separator: "/"), name)
    }

    internal static func renameItem(volume original: NTFSVolume, sourcePath: String,
                                    destinationPath: String, replaceExisting: Bool) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let ctx = try MutationContext(original)
        let sourceParts = try splitItemPath(sourcePath)
        let destination = try splitItemPath(destinationPath)
        let source = try ctx.volume.lookup(path: sourcePath)
        let record = try ctx.editableRecord(source.record.recordNumber)
        let oldParent = try ctx.volume.lookup(path: sourceParts.parent).record
        let newParent = try ctx.volume.lookup(path: destination.parent).record
        guard oldParent.isDirectory, newParent.isDirectory else { throw POSIXError(.ENOTDIR) }
        guard newParent.attribute(ofType: .attributeList) == nil else {
            throw NTFSError.unsupportedFeature("Directory attributes in extension records")
        }
        let table = try loadUpcase(volume: ctx.volume)
        let wanted = try collationKey(destination.name, upcase: table)
        var oldEntries = try readIndexEntries(volume: ctx.volume, parent: oldParent)
        var newEntries = oldParent.recordNumber == newParent.recordNumber ? oldEntries :
            try readIndexEntries(volume: ctx.volume, parent: newParent)
        if let existing = try newEntries.first(where: { try collationKey(entryName($0), upcase: table) == wanted }),
           u64(existing, 0) & 0x0000ffffffffffff != record.recordNumber {
            guard replaceExisting else { throw POSIXError(.EEXIST) }
            let other = try ctx.editableRecord(u64(existing, 0) & 0x0000ffffffffffff)
            guard other.isDirectory == record.isDirectory else { throw POSIXError(record.isDirectory ? .ENOTDIR : .EISDIR) }
            if other.isDirectory, try !ctx.volume.listDirectory(recordNumber: other.recordNumber).isEmpty { throw POSIXError(.ENOTEMPTY) }
            newEntries.removeAll { u64($0, 0) & 0x0000ffffffffffff == other.recordNumber }
            if oldParent.recordNumber == newParent.recordNumber { oldEntries = newEntries }
            try ctx.freeRecord(other)
        }
        if record.isDirectory {
            var ancestor = newParent.recordNumber
            var seen = Set<UInt64>()
            while ancestor != 5 {
                guard ancestor != record.recordNumber, seen.insert(ancestor).inserted else { throw POSIXError(.EINVAL) }
                let parent = try ctx.volume.readMFTRecord(number: ancestor)
                guard let bytes = parent.attribute(ofType: .fileName)?.residentData else { throw NTFSError.invalidIndexEntry }
                ancestor = try FileNameAttribute(data: bytes).parentDirectoryRecordNumber
            }
            guard newParent.recordNumber != record.recordNumber else { throw POSIXError(.EINVAL) }
        }
        let fixed = try ctx.fixed(record)
        let originalAttrs = try attributeParts(fixed)
        guard let oldName = record.allAttributes(ofType: .fileName).first?.residentData else { throw NTFSError.invalidIndexEntry }
        var key = Data(oldName.prefix(66))
        put(newParent.recordNumber | UInt64(newParent.header.sequenceNumber) << 48, into: &key, at: 0)
        key[64] = UInt8(destination.name.utf16.count)
        key[65] = 1
        key.append(utf16(destination.name))
        let nameID = record.allAttributes(ofType: .fileName)[0].attributeID
        let attrs = originalAttrs.filter { u32($0, 0) != 0x30 } + [resident(type: 0x30, name: nil, value: key, id: nameID)]
        let changed = try rebuildRecord(fixed, attributes: attrs, nextID: record.header.nextAttributeID, boot: ctx.volume.bootSector)
        let reference = record.recordNumber | UInt64(record.header.sequenceNumber) << 48
        oldEntries.removeAll { u64($0, 0) & 0x0000ffffffffffff == record.recordNumber }
        newEntries.removeAll { u64($0, 0) & 0x0000ffffffffffff == record.recordNumber }
        let newEntry = indexEntry(reference: reference, key: key)
        if oldParent.recordNumber == newParent.recordNumber {
            oldEntries.append(newEntry)
            try planDirectory(oldParent, entries: oldEntries, context: ctx)
        } else {
            newEntries.append(newEntry)
            try planDirectory(oldParent, entries: oldEntries, context: ctx)
            try planDirectory(newParent, entries: newEntries, context: ctx)
        }
        try ctx.stageRecord(record.recordNumber, changed)
        try ctx.commit()
    }

    internal static func setFileTimes(volume original: NTFSVolume, recordNumber: UInt64,
                                      creation: Date?, modification: Date?, access: Date?) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let ctx = try MutationContext(original)
        let record = try ctx.editableRecord(recordNumber)
        let fixed = try ctx.fixed(record)
        let parts = try attributeParts(fixed).map { part -> Data in
            let parsed = try NTFSAttribute(data: part, offset: 0)
            guard parsed.type == .standardInformation || parsed.type == .fileName else { return part }
            var copy = part
            let start = Int(u16(copy, 20)) + (parsed.type == .fileName ? 8 : 0)
            if let creation { put(FileTimeConverter.toFileTime(date: creation), into: &copy, at: start) }
            if let modification { put(FileTimeConverter.toFileTime(date: modification), into: &copy, at: start + 8) }
            if let access { put(FileTimeConverter.toFileTime(date: access), into: &copy, at: start + 24) }
            put(FileTimeConverter.toFileTime(date: Date()), into: &copy, at: start + 16)
            return copy
        }
        let raw = try rebuildRecord(fixed, attributes: parts, nextID: record.header.nextAttributeID, boot: ctx.volume.bootSector)
        try ctx.stageRecord(recordNumber, raw)
        try updateParentKeys(record: MFTRecord(recordNumber: recordNumber, rawData: raw), context: ctx)
        try ctx.commit()
    }
}
