import Foundation

/// Creates new files. Existing names are rejected; replacement, journal replay and
/// online raw-device writes are deliberately outside this engine's write contract.
public enum NTFSVolumeWriter {
    internal static let writeLock = NSLock()

    public static func sanitizeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: ":*?\"<>|/\\").union(.controlCharacters)
        let clean = name.unicodeScalars.map { illegal.contains($0) ? "_" : String($0) }
            .joined().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return clean.isEmpty ? "unnamed_file" : clean
    }

    @discardableResult
    public static func writeFile(volume originalVolume: NTFSVolume, directoryRecordNumber: UInt64 = 5,
                                 fileName: String, data: Data, isDirectory: Bool = false) throws -> UInt64 {
        writeLock.lock()
        defer { writeLock.unlock() }
        let volume = try NTFSVolume(blockDevice: originalVolume.blockDevice)
        let device = volume.blockDevice
        try prepareForWriting(volume)
        let name = sanitizeFileName(fileName)
        guard name.utf16.count <= 255 else {
            throw NTFSError.unsupportedFeature("File names may contain at most 255 UTF-16 code units")
        }
        let boot = volume.bootSector
        // The current file record builder implements 1024-byte records / 512-byte sectors.
        guard boot.mftRecordSizeBytes == 1024, boot.bytesPerSector == 512 else {
            throw NTFSError.unsupportedFeature("Writing currently requires 1024-byte MFT records and 512-byte sectors")
        }
        let cluster = UInt64(boot.clusterSizeBytes)
        let tx = WriteTransaction(device: device)
        let parent = try volume.readMFTRecord(number: directoryRecordNumber)
        guard parent.isInUse, parent.isDirectory else {
            throw NTFSError.notADirectory("MFT record \(directoryRecordNumber)")
        }
        guard parent.attribute(ofType: .attributeList) == nil else {
            throw NTFSError.unsupportedFeature("Directory attributes in extension records")
        }
        let upcase = try loadUpcase(volume: volume)
        let nameKey = try collationKey(name, upcase: upcase)
        var entries = try readIndexEntries(volume: volume, parent: parent)
        guard try !entries.contains(where: {
            try collationKey(entryName($0), upcase: upcase) == nameKey
        }) else {
            throw NTFSError.unsupportedFeature("A file named '\(name)' already exists")
        }
        let mft = try volume.readMFTRecord(number: 0)
        guard let mftBitmap = mft.attribute(ofType: .bitmap) else {
            throw NTFSError.unsupportedFeature("Missing $MFT allocation bitmap")
        }
        var recordBits = BitmapManager(data: try streamData(mftBitmap, volume: volume))
        guard let mftData = mft.defaultDataAttribute else {
            throw NTFSError.attributeNotFound(type: 0x80, name: nil)
        }
        var mftRuns = volume.mftRecordRuns
        let oldMFTSize = mftData.realDataSize
        var newMFTSize = oldMFTSize
        let capacity = min(Int(oldMFTSize) / 1024, recordBits.totalBits)
        var selected: UInt64?
        var sequence: UInt16 = 1
        if capacity > 24 {
            for n in 24..<capacity where !recordBits.isAllocated(at: n) {
                let raw = try readRuns(volume.mftRecordRuns, offset: UInt64(n) * 1024,
                                       count: 1024, cluster: cluster, device: device)
                if raw.prefix(4) == Data("FILE".utf8) {
                    let existing = try MFTRecord(recordNumber: UInt64(n), rawData: raw)
                    guard !existing.isInUse else { continue }
                    sequence = existing.header.sequenceNumber == 0 ? 1 : existing.header.sequenceNumber
                } else {
                    guard raw.allSatisfy({ $0 == 0 }) else {
                        throw NTFSError.unsupportedFeature("Unallocated MFT record has invalid nonzero contents")
                    }
                }
                selected = UInt64(n)
                break
            }
        }
        let bitmapRecord = try volume.readMFTRecord(number: 6)
        guard let clusterBitmapAttr = bitmapRecord.defaultDataAttribute else {
            throw NTFSError.attributeNotFound(type: 0x80, name: nil)
        }
        var clusterBits = BitmapManager(data: try streamData(clusterBitmapAttr, volume: volume))
        let totalClusters = boot.totalSectors / UInt64(boot.sectorsPerCluster)
        var rebuiltMFT: Data?
        var grownBitmapRuns: [DataRun]?
        var grewMFT = false
        if selected == nil {
            guard mft.attribute(ofType: .attributeList) == nil, mftData.flags.isEmpty else {
                throw NTFSError.unsupportedFeature("Extending an MFT with extension records or encoded data")
            }
            let allocatedBytes = mftRuns.reduce(UInt64(0)) { $0 + $1.clusterCount * cluster }
            let desiredBytes = ((oldMFTSize + 32 * 1024 + cluster - 1) / cluster) * cluster
            if desiredBytes > allocatedBytes {
                let more = try allocate(count: Int((desiredBytes - allocatedBytes) / cluster),
                                        bitmap: &clusterBits, limit: totalClusters)
                for run in more {
                    if let last = mftRuns.last, let lcn = last.startingLCN,
                       let next = run.startingLCN, lcn + last.clusterCount == next {
                        mftRuns.removeLast()
                        mftRuns.append(DataRun(clusterCount: last.clusterCount + run.clusterCount, startingLCN: lcn))
                    } else { mftRuns.append(run) }
                }
            }
            newMFTSize = desiredBytes
            let newRecordCount = Int(desiredBytes / 1024)
            var bitmapData = recordBits.data
            let bitmapBytes = max(bitmapData.count, ((newRecordCount + 63) / 64) * 8)
            bitmapData.append(Data(repeating: 0, count: bitmapBytes - bitmapData.count))
            recordBits = BitmapManager(data: bitmapData)
            selected = oldMFTSize / 1024
            grewMFT = true
        }
        guard let recordNumber = selected else { throw NTFSError.unsupportedFeature("No free MFT record") }
        try recordBits.setAllocated(at: Int(recordNumber), isAllocated: true)
        if grewMFT {
            let fixed = try fixedRecord(readRuns(volume.mftRecordRuns, offset: 0,
                count: 1024, cluster: cluster, device: device), boot: boot)
            let parts = try attributeParts(fixed).filter {
                let a = try NTFSAttribute(data: $0, offset: 0)
                return !(a.name == nil && (a.type == .data || a.type == .bitmap))
            }
            let dataPart = nonResident(type: 0x80, name: nil, runs: mftRuns,
                realSize: newMFTSize, cluster: cluster, id: mftData.attributeID)
            let bitmapPart: Data
            if mftBitmap.isNonResident {
                let runs = try allocate(count: Int((UInt64(recordBits.data.count) + cluster - 1) / cluster),
                                        bitmap: &clusterBits, limit: totalClusters)
                grownBitmapRuns = runs
                bitmapPart = nonResident(type: 0xb0, name: nil, runs: runs,
                    realSize: UInt64(recordBits.data.count), cluster: cluster, id: mftBitmap.attributeID)
                for run in mftBitmap.runs ?? [] {
                    guard let lcn = run.startingLCN else { throw NTFSError.corruptRunlist("Sparse MFT bitmap") }
                    for bit in lcn..<(lcn + run.clusterCount) {
                        try clusterBits.setAllocated(at: Int(bit), isAllocated: false)
                    }
                }
            } else {
                bitmapPart = resident(type: 0xb0, name: nil, value: recordBits.data, id: mftBitmap.attributeID)
            }
            rebuiltMFT = try rebuildRecord(fixed, attributes: parts + [dataPart, bitmapPart],
                nextID: mft.header.nextAttributeID, boot: boot)
        }
        var fileRuns: [DataRun]?
        // Resident capacity depends on the encoded name, not a fixed payload threshold.
        var fileRecord: Data
        do {
            fileRecord = try MFTRecordBuilder.buildFileRecord(
                recordNumber: recordNumber, sequenceNumber: sequence,
                parentDirectoryRecordNumber: directoryRecordNumber, fileName: name,
                fileContent: data, clusterSize: cluster)
        } catch NTFSError.unsupportedFeature {
            let count = Int((UInt64(data.count) + cluster - 1) / cluster)
            guard count > 0 else { throw NTFSError.unsupportedFeature("File record does not fit") }
            let runs = try allocate(count: count, bitmap: &clusterBits, limit: totalClusters)
            fileRuns = runs
            fileRecord = try MFTRecordBuilder.buildFileRecord(
                recordNumber: recordNumber, sequenceNumber: sequence,
                parentDirectoryRecordNumber: directoryRecordNumber, fileName: name,
                fileContent: data, dataRuns: runs, clusterSize: cluster)
        }
        // Use the actual parent sequence, including directories reused after deletion.
        var fixedFile = try fixedRecord(fileRecord, boot: boot)
        if let part = try attributeParts(fixedFile).first(where: { u32($0, 0) == 0x30 }) {
            let start = try attributeOffset(type: 0x30, name: nil, record: fixedFile)
            let valueOffset = Int(u16(part, 20))
            put(directoryRecordNumber | (UInt64(parent.header.sequenceNumber) << 48),
                into: &fixedFile, at: start + valueOffset)
            let allocatedBytes = fileRuns?.reduce(UInt64(0)) { $0 + $1.clusterCount * cluster } ?? 0
            put(allocatedBytes, into: &fixedFile, at: start + valueOffset + 40)
        }
        if isDirectory {
            guard data.isEmpty else { throw NTFSError.unsupportedFeature("Directory cannot have file payload") }
            put(UInt16(3), into: &fixedFile, at: 22)
            let fileNameStart = try attributeOffset(type: 0x30, name: nil, record: fixedFile)
            let fileNameValue = fileNameStart + Int(u16(fixedFile, fileNameStart + 20))
            put(UInt32(0x10000000), into: &fixedFile, at: fileNameValue + 56)
            let standardStart = try attributeOffset(type: 0x10, name: nil, record: fixedFile)
            let standardValue = standardStart + Int(u16(fixedFile, standardStart + 20))
            put(UInt32(0x10), into: &fixedFile, at: standardValue + 32)
            var rootHeader = Data(repeating: 0, count: 16)
            put(UInt32(0x30), into: &rootHeader, at: 0)
            put(UInt32(1), into: &rootHeader, at: 4)
            let indexSize = boot.indexRecordSizeBytes
            put(indexSize, into: &rootHeader, at: 8)
            let indexUnit = boot.clusterSizeBytes <= indexSize ? boot.clusterSizeBytes : UInt32(boot.bytesPerSector)
            rootHeader[12] = UInt8(indexSize / indexUnit)
            let attrs = try attributeParts(fixedFile).filter { u32($0, 0) != 0x80 } + [
                resident(type: 0x90, name: "$I30",
                         value: indexRoot(header: rootHeader, entries: [], lastChild: nil), id: 2)
            ]
            fileRecord = try rebuildRecord(fixedFile, attributes: attrs, nextID: 3, boot: boot)
        } else {
            fileRecord = sealRecord(fixedFile, boot: boot)
        }
        let child = try MFTRecord(recordNumber: recordNumber, rawData: fileRecord)
        guard let fn = child.attribute(ofType: .fileName)?.residentData else {
            throw NTFSError.attributeNotFound(type: 0x30, name: nil)
        }
        entries.append(indexEntry(reference: recordNumber | (UInt64(sequence) << 48), key: fn))
        // $UpCase is the volume's collation authority. Synthetic images without it
        // are writable only for ASCII names, avoiding locale-dependent ordering.
        var keyed: [(Data, [UInt16])] = try entries.map {
            ($0, try collationKey(entryName($0), upcase: upcase))
        }
        keyed.sort { $0.1.lexicographicallyPrecedes($1.1) }
        entries = keyed.map(\.0)

        let parentRaw = try readRuns(volume.mftRecordRuns, offset: directoryRecordNumber * 1024,
                                     count: 1024, cluster: cluster, device: device)
        let parentFixed = try fixedRecord(parentRaw, boot: boot)
        let parts = try attributeParts(parentFixed)
        let preserved = try parts.filter {
            let attr = try NTFSAttribute(data: $0, offset: 0)
            return !(attr.name == "$I30" &&
                [.indexRoot, .indexAllocation, .bitmap].contains(attr.type))
        }
        guard let oldRoot = parent.attribute(ofType: .indexRoot, name: "$I30")?.residentData,
              oldRoot.count >= 32, u32(oldRoot, 0) == 0x30, u32(oldRoot, 4) == 1 else {
            throw NTFSError.corruptDirectoryIndex("Unsupported or missing filename index")
        }
        var nextID = parent.header.nextAttributeID
        func nextAttributeID() throws -> UInt16 {
            guard nextID < UInt16.max else {
                throw NTFSError.unsupportedFeature("Attribute identifiers exhausted")
            }
            defer { nextID += 1 }
            return nextID
        }
        let rootID = parent.attribute(ofType: .indexRoot, name: "$I30")!.attributeID
        let smallValue = indexRoot(header: oldRoot, entries: entries, lastChild: nil)
        var indexAttrs = [resident(type: 0x90, name: "$I30", value: smallValue, id: rootID)]
        var newIndexData = Data()
        var indexRuns: [DataRun] = []
        if !recordFits(parentFixed, attributes: preserved + indexAttrs) {
            let blockSize = Int(u32(oldRoot, 8))
            guard blockSize >= 1024, blockSize <= 65536, blockSize % 512 == 0,
                  blockSize.nonzeroBitCount == 1 else {
                throw NTFSError.unsupportedFeature("Unsupported index block geometry")
            }
            let built = try buildIndexTree(entries: entries, blockSize: blockSize,
                                           clusterSize: Int(cluster))
            newIndexData = built.data
            indexRuns = try allocate(count: (newIndexData.count + Int(cluster) - 1) / Int(cluster),
                                     bitmap: &clusterBits, limit: totalClusters)
            let rootValue = indexRoot(header: oldRoot, entries: [], lastChild: built.rootVCN)
            var bits = Data(repeating: 0, count: max(8, ((built.blockCount + 63) / 64) * 8))
            for i in 0..<built.blockCount { bits[i / 8] |= UInt8(1 << (i % 8)) }
            indexAttrs = [
                resident(type: 0x90, name: "$I30", value: rootValue, id: rootID),
                nonResident(type: 0xa0, name: "$I30", runs: indexRuns,
                            realSize: UInt64(newIndexData.count), cluster: cluster,
                            id: try nextAttributeID()),
                resident(type: 0xb0, name: "$I30", value: bits, id: try nextAttributeID())
            ]
        }
        let newParent = try rebuildRecord(parentFixed, attributes: preserved + indexAttrs,
                                          nextID: nextID, boot: boot)

        // Release old index extents only after the new tree has its own allocation.
        if let oldAllocation = parent.attribute(ofType: .indexAllocation, name: "$I30") {
            guard oldAllocation.flags.isEmpty, let runs = oldAllocation.runs else {
                throw NTFSError.unsupportedFeature("Unsupported index allocation flags")
            }
            for run in runs {
                guard let lcn = run.startingLCN, lcn + run.clusterCount <= totalClusters else {
                    throw NTFSError.corruptRunlist("Invalid old index allocation")
                }
                for bit in lcn..<(lcn + run.clusterCount) {
                    try clusterBits.setAllocated(at: Int(bit), isAllocated: false)
                }
            }
        }

        // Everything above is preflight: no disk bytes have changed.
        if grewMFT {
            var initialized = Data()
            for number in (oldMFTSize / 1024)..<(newMFTSize / 1024) {
                var record = Data(repeating: 0, count: 1024)
                record.replaceSubrange(0..<4, with: Data("FILE".utf8))
                put(UInt16(48), into: &record, at: 4)
                put(UInt16(3), into: &record, at: 6)
                put(UInt16(1), into: &record, at: 16)
                put(UInt16(56), into: &record, at: 20)
                put(UInt32(64), into: &record, at: 24)
                put(UInt32(1024), into: &record, at: 28)
                put(UInt32(number), into: &record, at: 44)
                put(UInt32.max, into: &record, at: 56)
                initialized.append(sealRecord(record, boot: boot))
            }
            try stageRuns(mftRuns, offset: oldMFTSize,
                data: initialized, cluster: cluster, tx: tx)
        }
        if let runs = fileRuns {
            try stageRuns(runs, offset: 0, data: data, cluster: cluster, tx: tx)
        }
        if !newIndexData.isEmpty {
            try stageRuns(indexRuns, offset: 0, data: newIndexData, cluster: cluster, tx: tx)
        }
        try stageMFTRecord(recordNumber, data: fileRecord, runs: mftRuns, volume: volume, tx: tx)
        try stageBitmap(clusterBitmapAttr, recordNumber: 6, bitmap: clusterBits, volume: volume, tx: tx)
        if let rebuiltMFT {
            if let runs = grownBitmapRuns {
                try stageRuns(runs, offset: 0, data: recordBits.data, cluster: cluster, tx: tx)
            }
            try stageRuns(mftRuns, offset: 0, data: rebuiltMFT, cluster: cluster, tx: tx)
            let mirror = try volume.readMFTRecord(number: 1)
            guard let runs = mirror.defaultDataAttribute?.runs else {
                throw NTFSError.corruptRunlist("Missing MFT mirror runs")
            }
            try stageRuns(runs, offset: 0, data: rebuiltMFT, cluster: cluster, tx: tx)
        } else {
            try stageBitmap(mftBitmap, recordNumber: 0, bitmap: recordBits, volume: volume, tx: tx)
        }
        try stageMFTRecord(directoryRecordNumber, data: newParent, runs: mftRuns, volume: volume, tx: tx)
        try tx.commit()
        return recordNumber
    }

    // MARK: Stream mapping and rollback

    internal static func stageMFTRecord(_ number: UInt64, data: Data, runs: [DataRun],
                                        volume: NTFSVolume, tx: WriteTransaction) throws {
        let cluster = UInt64(volume.bootSector.clusterSizeBytes)
        try stageRuns(runs, offset: number * 1024, data: data, cluster: cluster, tx: tx)
        let mirror = try volume.readMFTRecord(number: 1)
        if let attr = mirror.defaultDataAttribute, let mirrorRuns = attr.runs,
           (number + 1) * 1024 <= attr.realDataSize {
            try stageRuns(mirrorRuns, offset: number * 1024, data: data, cluster: cluster, tx: tx)
        }
    }

    internal final class WriteTransaction {
        let device: BlockDevice
        /// `preserve` is false for bytes that are not yet part of any visible content
        /// (fresh clusters, data past the initialized size); rollback skips them.
        var writes: [(offset: UInt64, data: Data, preserve: Bool)] = []
        init(device: BlockDevice) { self.device = device }
        func stage(offset: UInt64, data: Data, preserve: Bool = true) throws {
            guard offset <= device.size, UInt64(data.count) <= device.size - offset else {
                throw BlockDeviceError.outOfBounds(offset: offset, requested: data.count, totalSize: device.size)
            }
            writes.append((offset, data, preserve))
        }
        func commit() throws {
            // Snapshot before the first write, including ranges in reused free clusters.
            let originals = try writes.map { write -> Data? in
                guard write.preserve else { return nil }
                let original = try device.read(offset: write.offset, count: write.data.count)
                guard original.count == write.data.count else {
                    throw BlockDeviceError.readFailed(errno: 5, message: "Short read before write")
                }
                return original
            }
            var attempted = 0
            do {
                for write in writes {
                    attempted += 1 // A throwing device may have partially written this range.
                    try device.write(offset: write.offset, data: write.data)
                }
                try device.flush()
            } catch {
                let originalError = error
                var rollbackFailed = false
                for i in (0..<attempted).reversed() {
                    guard let original = originals[i] else { continue }
                    do { try device.write(offset: writes[i].offset, data: original) }
                    catch { rollbackFailed = true }
                }
                do { try device.flush() } catch { rollbackFailed = true }
                if rollbackFailed {
                    throw BlockDeviceError.writeFailed(errno: 5,
                        message: "Write failed and rollback was incomplete. Stop using this volume and check it.")
                }
                throw originalError
            }
        }
    }

    internal static func readRuns(_ runs: [DataRun], offset: UInt64, count: Int,
                                 cluster: UInt64, device: BlockDevice) throws -> Data {
        var result = Data()
        try mapRuns(runs, offset: offset, count: count, cluster: cluster) { disk, length in
            let bytes = try device.read(offset: disk, count: length)
            guard bytes.count == length else {
                throw BlockDeviceError.readFailed(errno: 5, message: "Short NTFS stream read")
            }
            result.append(bytes)
        }
        return result
    }

    internal static func mapRuns(_ runs: [DataRun], offset: UInt64, count: Int, cluster: UInt64,
                                body: (UInt64, Int) throws -> Void) throws {
        var virtualStart: UInt64 = 0
        var position = offset
        var remaining = count
        for run in runs {
            let runBytes = run.clusterCount * cluster
            if remaining > 0, position >= virtualStart, position - virtualStart < runBytes {
                guard let lcn = run.startingLCN else {
                    throw NTFSError.unsupportedFeature("Sparse metadata writes")
                }
                let within = position - virtualStart
                let length = min(remaining, Int(runBytes - within))
                try body(lcn * cluster + within, length)
                position += UInt64(length)
                remaining -= length
            }
            virtualStart += runBytes
            if remaining == 0 { return }
        }
        guard remaining == 0 else { throw NTFSError.corruptRunlist("Stream write exceeds mapped runs") }
    }

    internal static func stageRuns(_ runs: [DataRun], offset: UInt64, data: Data,
                                  cluster: UInt64, tx: WriteTransaction, preserve: Bool = true) throws {
        var consumed = 0
        let base = data.startIndex
        try mapRuns(runs, offset: offset, count: data.count, cluster: cluster) { disk, length in
            try tx.stage(offset: disk, data: data.subdata(in: (base + consumed)..<(base + consumed + length)),
                         preserve: preserve)
            consumed += length
        }
    }

    internal static func streamData(_ attr: NTFSAttribute, volume: NTFSVolume) throws -> Data {
        guard attr.flags.isEmpty else { throw NTFSError.unsupportedFeature("Encoded metadata stream") }
        if let data = attr.residentData { return data }
        guard let runs = attr.runs else { throw NTFSError.corruptRunlist("Missing metadata runs") }
        return try readRuns(runs, offset: 0, count: Int(attr.realDataSize),
                            cluster: UInt64(volume.bootSector.clusterSizeBytes), device: volume.blockDevice)
    }

    internal static func stageAttribute(_ attr: NTFSAttribute, recordNumber: UInt64, value: Data,
                                       volume: NTFSVolume, tx: WriteTransaction) throws {
        guard UInt64(value.count) == attr.realDataSize else {
            throw NTFSError.unsupportedFeature("Growing metadata attributes")
        }
        let cluster = UInt64(volume.bootSector.clusterSizeBytes)
        if let runs = attr.runs {
            try stageRuns(runs, offset: 0, data: value, cluster: cluster, tx: tx)
        } else {
            var raw = try fixedRecord(readRuns(volume.mftRecordRuns, offset: recordNumber * 1024,
                                               count: 1024, cluster: cluster, device: volume.blockDevice),
                                      boot: volume.bootSector)
            let off = try attributeOffset(type: attr.type.rawValue, name: attr.name, record: raw)
            let valueOff = off + Int(u16(raw, off + 20))
            raw.replaceSubrange(valueOff..<(valueOff + value.count), with: value)
            let sealed = sealRecord(raw, boot: volume.bootSector)
            try stageRuns(volume.mftRecordRuns, offset: recordNumber * 1024,
                          data: sealed, cluster: cluster, tx: tx)
            // $MFTMirr duplicates the first records, including record zero's bitmap header.
            let mirror = try volume.readMFTRecord(number: 1)
            if let attr = mirror.defaultDataAttribute, let runs = attr.runs,
               (recordNumber + 1) * 1024 <= attr.realDataSize {
                try stageRuns(runs, offset: recordNumber * 1024, data: sealed, cluster: cluster, tx: tx)
            }
        }
    }

    /// Prefers one contiguous extent at or after `hint` (typically just past a stream's
    /// last cluster, so appends stay contiguous); otherwise allocates first-fit from the
    /// hint, wrapping to the start of the volume.
    internal static func allocate(count: Int, bitmap: inout BitmapManager, limit: UInt64,
                                  near hint: UInt64 = 0) throws -> [DataRun] {
        guard count > 0 else { return [] }
        let end = min(bitmap.totalBits, Int(min(limit, UInt64(Int.max))))
        let pivot = Int(min(hint, UInt64(end)))
        if let start = bitmap.firstFreeRun(length: count, from: pivot, below: end)
            ?? bitmap.firstFreeRun(length: count, from: 0, below: pivot) {
            for bit in start..<(start + count) { try bitmap.setAllocated(at: bit, isAllocated: true) }
            return [DataRun(clusterCount: UInt64(count), startingLCN: UInt64(start))]
        }
        var remaining = count
        var runs: [DataRun] = []
        for (from, to) in [(pivot, end), (0, pivot)] {
            var i = from
            while remaining > 0, let start = bitmap.firstFree(from: i, below: to) {
                i = start
                while i < to && remaining > 0 && !bitmap.isAllocated(at: i) {
                    try bitmap.setAllocated(at: i, isAllocated: true)
                    i += 1
                    remaining -= 1
                }
                runs.append(DataRun(clusterCount: UInt64(i - start), startingLCN: UInt64(start)))
            }
        }
        guard remaining == 0 else {
            // Leave the bitmap as it was, so callers can retry with a smaller request.
            for run in runs {
                for bit in run.startingLCN!..<(run.startingLCN! + run.clusterCount) {
                    try bitmap.setAllocated(at: Int(bit), isAllocated: false)
                }
            }
            throw NTFSError.unsupportedFeature("Insufficient free clusters")
        }
        return runs
    }

    /// Appends runs, joining physically adjacent ones.
    internal static func appendRuns(_ more: [DataRun], to runs: inout [DataRun]) {
        for run in more {
            if let last = runs.last, let lcn = last.startingLCN, let next = run.startingLCN,
               lcn + last.clusterCount == next {
                runs[runs.count - 1] = DataRun(clusterCount: last.clusterCount + run.clusterCount, startingLCN: lcn)
            } else {
                runs.append(run)
            }
        }
    }

    /// Stages only the sectors of a bitmap that changed. Resident bitmaps are small and
    /// are rewritten with their record.
    internal static func stageBitmap(_ attr: NTFSAttribute, recordNumber: UInt64, bitmap: BitmapManager,
                                     volume: NTFSVolume, tx: WriteTransaction) throws {
        guard let dirty = bitmap.dirtyBytes else { return }
        guard let runs = attr.runs else {
            return try stageAttribute(attr, recordNumber: recordNumber, value: bitmap.data, volume: volume, tx: tx)
        }
        guard UInt64(bitmap.data.count) == attr.realDataSize else {
            throw NTFSError.unsupportedFeature("Growing metadata attributes")
        }
        let start = dirty.lowerBound / 512 * 512
        let end = min(bitmap.data.count, (dirty.upperBound + 511) / 512 * 512)
        let base = bitmap.data.startIndex
        try stageRuns(runs, offset: UInt64(start), data: Data(bitmap.data[(base + start)..<(base + end)]),
                      cluster: UInt64(volume.bootSector.clusterSizeBytes), tx: tx)
    }

    // MARK: Directory B-tree

    internal static func readIndexEntries(volume: NTFSVolume, parent: MFTRecord) throws -> [Data] {
        guard let root = parent.attribute(ofType: .indexRoot, name: "$I30")?.residentData else {
            throw NTFSError.attributeNotFound(type: 0x90, name: "$I30")
        }
        var entries: [Data] = []
        var visited = Set<UInt64>()
        let allocation = parent.attribute(ofType: .indexAllocation, name: "$I30")
        guard root.count >= 32 else { throw NTFSError.invalidIndexEntry }
        let indexSize = Int(u32(root, 8))
        let unit = UInt64(Int(volume.bootSector.clusterSizeBytes) <= indexSize ?
                          Int(volume.bootSector.clusterSizeBytes) : Int(volume.bootSector.bytesPerSector))
        func walk(_ bytes: Data, header: Int) throws {
            guard header >= 0, header + 16 <= bytes.count else { throw NTFSError.invalidIndexEntry }
            var off = header + Int(u32(bytes, header))
            let end = header + Int(u32(bytes, header + 4))
            guard off >= header + 16, end <= bytes.count, off <= end else {
                throw NTFSError.invalidIndexEntry
            }
            var terminated = false
            while off + 16 <= end {
                let entry = try IndexEntryParser.parse(data: bytes, offset: off)
                guard off + Int(entry.entryLength) <= end else { throw NTFSError.invalidIndexEntry }
                if let vcn = entry.subNodeVCN {
                    guard visited.insert(vcn).inserted, let runs = allocation?.runs else {
                        throw NTFSError.corruptDirectoryIndex("Invalid or cyclic child reference")
                    }
                    var block = try readRuns(runs, offset: vcn * unit, count: indexSize,
                                             cluster: UInt64(volume.bootSector.clusterSizeBytes),
                                             device: volume.blockDevice)
                    guard block.count >= 40, block.prefix(4) == Data("INDX".utf8),
                          u64(block, 16) == vcn else { throw NTFSError.invalidIndexEntry }
                    try FixupApplier.applyFixup(data: &block, updateSequenceOffset: Int(u16(block, 4)),
                        updateSequenceSize: Int(u16(block, 6)), bytesPerSector: Int(volume.bootSector.bytesPerSector))
                    try walk(block, header: 24)
                }
                if entry.isLastEntry {
                    guard off + Int(entry.entryLength) == end else { throw NTFSError.invalidIndexEntry }
                    terminated = true
                    break
                }
                guard entry.fileName != nil, entry.streamLength >= 66 else {
                    throw NTFSError.invalidIndexEntry
                }
                let key = bytes.subdata(in: (off + 16)..<(off + 16 + Int(entry.streamLength)))
                let reference = u64(bytes, off)
                entries.append(indexEntry(reference: reference, key: key))
                off += Int(entry.entryLength)
            }
            guard terminated else { throw NTFSError.invalidIndexEntry }
        }
        try walk(root, header: 16)
        return entries
    }

    internal struct TreeNode {
        var entries: [Data]
        var lastChild: UInt64?
    }

    internal static func buildIndexTree(entries: [Data], blockSize: Int,
                                       clusterSize: Int) throws -> (data: Data, rootVCN: UInt64, blockCount: Int) {
        let usaCount = blockSize / 512 + 1
        let entriesStart = align8(40 + usaCount * 2)
        let capacity = blockSize - entriesStart
        let vcnStep = UInt64(blockSize / (clusterSize <= blockSize ? clusterSize : 512))
        var nodes: [TreeNode] = []
        func append(_ node: TreeNode) -> UInt64 {
            let vcn = UInt64(nodes.count) * vcnStep
            nodes.append(node)
            return vcn
        }
        // Each promoted separator is removed from its child; every key occurs once.
        var levelEntries = entries
        var lastChild: UInt64?
        while true {
            let terminalBytes = lastChild == nil ? 16 : 24
            var groups: [TreeNode] = []
            var separators: [Data] = []
            var group: [Data] = []
            var used = terminalBytes
            for entry in levelEntries {
                guard entry.count + terminalBytes <= capacity else {
                    throw NTFSError.unsupportedFeature("Index key exceeds block capacity")
                }
                if used + entry.count > capacity {
                    guard let separator = group.popLast() else { throw NTFSError.invalidIndexEntry }
                    let child = (u16(separator, 12) & 1) != 0 ? u64(separator, separator.count - 8) : nil
                    groups.append(TreeNode(entries: group, lastChild: child))
                    separators.append(separator)
                    group = []
                    used = terminalBytes
                }
                group.append(entry)
                used += entry.count
            }
            groups.append(TreeNode(entries: group, lastChild: lastChild))
            if groups.count == 1 {
                let root = append(groups[0])
                var output = Data()
                for (i, node) in nodes.enumerated() {
                    var block = Data(repeating: 0, count: blockSize)
                    block.replaceSubrange(0..<4, with: Data("INDX".utf8))
                    put(UInt16(40), into: &block, at: 4)
                    put(UInt16(usaCount), into: &block, at: 6)
                    put(UInt64(i) * vcnStep, into: &block, at: 16)
                    let stream = node.entries.reduce(into: Data()) { $0.append($1) } +
                        endEntry(child: node.lastChild)
                    put(UInt32(entriesStart - 24), into: &block, at: 24)
                    put(UInt32(entriesStart - 24 + stream.count), into: &block, at: 28)
                    put(UInt32(blockSize - 24), into: &block, at: 32)
                    block[36] = node.lastChild == nil ? 0 : 1
                    block.replaceSubrange(entriesStart..<(entriesStart + stream.count), with: stream)
                    FixupApplier.prepareForWrite(data: &block, updateSequenceOffset: 40,
                        updateSequenceSize: usaCount, bytesPerSector: 512)
                    output.append(block)
                }
                return (output, root, nodes.count)
            }
            var next: [Data] = []
            for i in 0..<groups.count {
                let vcn = append(groups[i])
                if i < separators.count {
                    let key = separators[i]
                    next.append(indexEntry(reference: u64(key, 0),
                        key: key.subdata(in: 16..<(16 + Int(u16(key, 10)))), child: vcn))
                } else { lastChild = vcn }
            }
            levelEntries = next
        }
    }

    internal static func entryName(_ entry: Data) throws -> String {
        guard entry.count >= 82 else { throw NTFSError.invalidIndexEntry }
        let key = entry.subdata(in: 16..<(16 + Int(u16(entry, 10))))
        return try FileNameAttribute(data: key).name
    }

    internal static func loadUpcase(volume: NTFSVolume) throws -> Data? {
        let record = try volume.readMFTRecord(number: 10)
        guard let attr = record.defaultDataAttribute, attr.realDataSize > 0 else { return nil }
        let bytes = try streamData(attr, volume: volume)
        guard bytes.count == 131072 else {
            throw NTFSError.unsupportedFeature("Invalid $UpCase table")
        }
        return bytes
    }

    internal static func collationKey(_ name: String, upcase: Data?) throws -> [UInt16] {
        try name.utf16.map { unit in
            if let table = upcase { return u16(table, Int(unit) * 2) }
            guard unit < 128 else {
                throw NTFSError.unsupportedFeature("Non-ASCII writes require the volume's $UpCase table")
            }
            return (97...122).contains(unit) ? unit - 32 : unit
        }
    }

    internal static func indexEntry(reference: UInt64, key: Data, child: UInt64? = nil) -> Data {
        var entry = Data(repeating: 0, count: align8(16 + key.count) + (child == nil ? 0 : 8))
        put(reference, into: &entry, at: 0)
        put(UInt16(entry.count), into: &entry, at: 8)
        put(UInt16(key.count), into: &entry, at: 10)
        put(UInt16(child == nil ? 0 : 1), into: &entry, at: 12)
        entry.replaceSubrange(16..<(16 + key.count), with: key)
        if let vcn = child { put(vcn, into: &entry, at: entry.count - 8) }
        return entry
    }

    internal static func endEntry(child: UInt64?) -> Data {
        var entry = Data(repeating: 0, count: child == nil ? 16 : 24)
        put(UInt16(entry.count), into: &entry, at: 8)
        put(UInt16(child == nil ? 2 : 3), into: &entry, at: 12)
        if let vcn = child { put(vcn, into: &entry, at: entry.count - 8) }
        return entry
    }

    internal static func indexRoot(header: Data, entries: [Data], lastChild: UInt64?) -> Data {
        var value = Data(header.prefix(16))
        let stream = entries.reduce(into: Data()) { $0.append($1) } + endEntry(child: lastChild)
        var node = Data(repeating: 0, count: 16)
        put(UInt32(16), into: &node, at: 0)
        put(UInt32(16 + stream.count), into: &node, at: 4)
        put(UInt32(16 + stream.count), into: &node, at: 8)
        node[12] = lastChild == nil ? 0 : 1
        value.append(node)
        value.append(stream)
        return value
    }

    // MARK: Attribute records

    internal static func resident(type: UInt32, name: String?, value: Data, id: UInt16) -> Data {
        let nameBytes = utf16(name ?? "")
        let start = align8(24 + nameBytes.count)
        var attr = Data(repeating: 0, count: align8(start + value.count))
        put(type, into: &attr, at: 0)
        put(UInt32(attr.count), into: &attr, at: 4)
        attr[9] = UInt8(nameBytes.count / 2)
        put(UInt16(nameBytes.isEmpty ? 0 : 24), into: &attr, at: 10)
        put(id, into: &attr, at: 14)
        put(UInt32(value.count), into: &attr, at: 16)
        put(UInt16(start), into: &attr, at: 20)
        attr.replaceSubrange(24..<(24 + nameBytes.count), with: nameBytes)
        attr.replaceSubrange(start..<(start + value.count), with: value)
        return attr
    }

    internal static func nonResident(type: UInt32, name: String?, runs: [DataRun], realSize: UInt64,
                                    cluster: UInt64, id: UInt16) -> Data {
        let nameBytes = utf16(name ?? "")
        let start = align8(64 + nameBytes.count)
        let encoded = DataRunEncoder.encode(runs: runs)
        let clusters = runs.reduce(UInt64(0)) { $0 + $1.clusterCount }
        var attr = Data(repeating: 0, count: align8(start + encoded.count))
        put(type, into: &attr, at: 0)
        put(UInt32(attr.count), into: &attr, at: 4)
        attr[8] = 1
        attr[9] = UInt8(nameBytes.count / 2)
        put(UInt16(64), into: &attr, at: 10)
        put(id, into: &attr, at: 14)
        put(clusters - 1, into: &attr, at: 24)
        put(UInt16(start), into: &attr, at: 32)
        put(clusters * cluster, into: &attr, at: 40)
        put(realSize, into: &attr, at: 48)
        put(realSize, into: &attr, at: 56)
        attr.replaceSubrange(64..<(64 + nameBytes.count), with: nameBytes)
        attr.replaceSubrange(start..<(start + encoded.count), with: encoded)
        return attr
    }

    internal static func fixedRecord(_ raw: Data, boot: BootSector) throws -> Data {
        var data = raw
        let header = try MFTRecordHeader(data: data)
        try FixupApplier.applyFixup(data: &data,
            updateSequenceOffset: Int(header.updateSequenceOffset),
            updateSequenceSize: Int(header.updateSequenceSize), bytesPerSector: Int(boot.bytesPerSector))
        return data
    }

    internal static func sealRecord(_ fixed: Data, boot: BootSector) -> Data {
        var data = fixed
        FixupApplier.prepareForWrite(data: &data, updateSequenceOffset: Int(u16(data, 4)),
            updateSequenceSize: Int(u16(data, 6)), bytesPerSector: Int(boot.bytesPerSector))
        return data
    }

    internal static func attributeParts(_ raw: Data) throws -> [Data] {
        var offset = Int(u16(raw, 20))
        var parts: [Data] = []
        while offset + 8 <= raw.count {
            if u32(raw, offset) == UInt32.max { return parts }
            guard offset + 16 <= raw.count else { throw NTFSError.invalidIndexEntry }
            let attr = try NTFSAttribute(data: raw, offset: offset)
            guard attr.recordLength >= 16 else { throw NTFSError.invalidIndexEntry }
            let end = offset + Int(attr.recordLength)
            parts.append(raw.subdata(in: offset..<end))
            offset = end
        }
        throw NTFSError.invalidIndexEntry
    }

    internal static func attributeOffset(type: UInt32, name: String?, record: Data) throws -> Int {
        var offset = Int(u16(record, 20))
        for part in try attributeParts(record) {
            let attr = try NTFSAttribute(data: part, offset: 0)
            if attr.type.rawValue == type && attr.name == name { return offset }
            offset += part.count
        }
        throw NTFSError.attributeNotFound(type: type, name: name)
    }

    internal static func recordFits(_ fixed: Data, attributes: [Data]) -> Bool {
        Int(u16(fixed, 20)) + attributes.reduce(0) { $0 + $1.count } + 8 <= fixed.count
    }

    internal static func rebuildRecord(_ fixed: Data, attributes: [Data], nextID: UInt16,
                                       boot: BootSector) throws -> Data {
        let sorted = try attributes.map { (try NTFSAttribute(data: $0, offset: 0), $0) }
            .sorted { a, b in
                if a.0.type.rawValue != b.0.type.rawValue { return a.0.type.rawValue < b.0.type.rawValue }
                return (a.0.name ?? "").utf16.lexicographicallyPrecedes((b.0.name ?? "").utf16)
            }.map(\.1)
        guard recordFits(fixed, attributes: sorted) else {
            throw NTFSError.unsupportedFeature("Directory record capacity exceeded; extension records required")
        }
        let start = Int(u16(fixed, 20))
        var out = fixed
        out.replaceSubrange(start..<out.count, with: Data(repeating: 0, count: out.count - start))
        var offset = start
        for attr in sorted {
            out.replaceSubrange(offset..<(offset + attr.count), with: attr)
            offset += attr.count
        }
        put(UInt32.max, into: &out, at: offset)
        put(UInt32(offset + 8), into: &out, at: 24)
        put(nextID, into: &out, at: 40)
        return sealRecord(out, boot: boot)
    }

    internal static func align8(_ n: Int) -> Int { (n + 7) & ~7 }
    internal static func u16(_ d: Data, _ p: Int) -> UInt16 {
        UInt16(d[d.startIndex + p]) | UInt16(d[d.startIndex + p + 1]) << 8
    }
    internal static func u32(_ d: Data, _ p: Int) -> UInt32 {
        UInt32(u16(d, p)) | UInt32(u16(d, p + 2)) << 16
    }
    internal static func u64(_ d: Data, _ p: Int) -> UInt64 {
        UInt64(u32(d, p)) | UInt64(u32(d, p + 4)) << 32
    }
    internal static func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
    internal static func utf16(_ string: String) -> Data {
        var bytes = Data()
        for unit in string.utf16 { var le = unit.littleEndian; withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) } }
        return bytes
    }
}
