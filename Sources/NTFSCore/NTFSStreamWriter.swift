import Foundation

/// Changes to an existing non-resident $DATA stream that touch only the written byte
/// range, newly allocated clusters and the file record. The whole-stream path in
/// `changeData` remains for resident streams and resident/non-resident conversion.
extension NTFSVolumeWriter {
    /// Sequential writers extend a stream chunk by chunk. Reserving headroom keeps such
    /// streams contiguous; `syncDirectoryEntry` returns unused headroom on close.
    static let appendHeadroomBytes: UInt64 = 64 << 20

    /// Plans an in-place change and stages the data. Returns the rebuilt, sealed record
    /// (not yet staged), or nil when the whole-stream path must handle the change. A nil
    /// result may leave reserved clusters in `ctx`, which must then be discarded.
    static func planStreamInPlace(_ ctx: MutationContext, record: MFTRecord, offset: UInt64,
                                  data: Data, size: UInt64?, touch: Bool = true) throws -> Data? {
        guard let old = record.defaultDataAttribute, old.flags.isEmpty,
              case .nonResident(let lowest, _, _, let realSize, let initializedSize, let runs) = old.payload,
              lowest == 0, !runs.isEmpty, runs.allSatisfy({ !$0.isSparse }) else { return nil }
        let cluster = ctx.cluster
        let end = offset + UInt64(data.count)
        let finalSize = size ?? max(realSize, end)
        let need = (finalSize + cluster - 1) / cluster
        // Truncation below one cluster is cheap on the whole-stream path, which also
        // makes the stream resident again when it fits.
        guard need > 1 || size == nil else { return nil }
        let have = runs.reduce(UInt64(0)) { $0 + $1.clusterCount }
        var newRuns = runs
        if need > have {
            let headroom = size == nil ? min(have, appendHeadroomBytes / cluster) : 0
            let last = runs[runs.count - 1]
            let hint = last.startingLCN! + last.clusterCount
            let more: [DataRun]
            do {
                more = try ctx.allocateClusters(Int(need - have + headroom), near: hint)
            } catch where headroom > 0 {
                more = try ctx.allocateClusters(Int(need - have), near: hint) // Nearly full volume.
            }
            appendRuns(more, to: &newRuns)
        } else if size != nil, need < have {
            var keep = need
            var kept: [DataRun] = [], freed: [DataRun] = []
            for run in runs {
                let lcn = run.startingLCN!
                if keep >= run.clusterCount {
                    kept.append(run)
                    keep -= run.clusterCount
                } else if keep > 0 {
                    kept.append(DataRun(clusterCount: keep, startingLCN: lcn))
                    freed.append(DataRun(clusterCount: run.clusterCount - keep, startingLCN: lcn + keep))
                    keep = 0
                } else {
                    freed.append(run)
                }
            }
            try ctx.releaseRuns(freed)
            newRuns = kept
        }

        // Bytes past the initialized size read as zeros without being stored. A write
        // beyond it must first zero the gap, which is not yet visible content.
        var initialized = min(initializedSize, realSize, finalSize)
        if !data.isEmpty {
            if offset > initialized {
                let zeros = Data(count: 1 << 20)
                var position = initialized
                while position < offset {
                    let count = Int(min(UInt64(zeros.count), offset - position))
                    try stageRuns(newRuns, offset: position, data: zeros.prefix(count), cluster: cluster,
                                  tx: ctx.transaction, preserve: false)
                    position += UInt64(count)
                }
            }
            // Only overwritten initialized bytes need a rollback snapshot.
            let visibleEnd = min(end, initialized)
            if offset < visibleEnd {
                let split = Int(visibleEnd - offset)
                try stageRuns(newRuns, offset: offset, data: data.prefix(split), cluster: cluster, tx: ctx.transaction)
                if split < data.count {
                    try stageRuns(newRuns, offset: visibleEnd, data: data.dropFirst(split), cluster: cluster,
                                  tx: ctx.transaction, preserve: false)
                }
            } else {
                try stageRuns(newRuns, offset: offset, data: data, cluster: cluster, tx: ctx.transaction, preserve: false)
            }
            initialized = max(initialized, end)
        }

        var fixed = try ctx.fixed(record)
        var parts = try attributeParts(fixed)
        guard let index = try parts.firstIndex(where: {
            let attr = try NTFSAttribute(data: $0, offset: 0)
            return attr.type == .data && attr.name == nil
        }) else { return nil }
        var attr = newRuns == runs ? parts[index]
            : nonResident(type: 0x80, name: nil, runs: newRuns, realSize: finalSize, cluster: cluster, id: old.attributeID)
        put(finalSize, into: &attr, at: 48)
        put(initialized, into: &attr, at: 56)
        parts[index] = attr
        if touch, let si = parts.firstIndex(where: { u32($0, 0) == 0x10 }) {
            let now = FileTimeConverter.toFileTime(date: Date())
            let value = Int(u16(parts[si], 20))
            put(now, into: &parts[si], at: value + 8)
            put(now, into: &parts[si], at: value + 16)
        }
        guard recordFits(fixed, attributes: parts) else { return nil }
        fixed = try rebuildRecord(fixed, attributes: parts, nextID: record.header.nextAttributeID,
                                  boot: ctx.volume.bootSector)
        return fixed
    }

    /// Copies times from $STANDARD_INFORMATION and sizes from $DATA into the record's
    /// $FILE_NAME attributes, which directory index entries duplicate.
    static func refreshFileNames(_ sealed: Data, boot: BootSector) throws -> Data {
        let fixed = try fixedRecord(sealed, boot: boot)
        var parts = try attributeParts(fixed)
        let attrs = try parts.map { try NTFSAttribute(data: $0, offset: 0) }
        guard let si = attrs.firstIndex(where: { $0.type == .standardInformation }) else { return sealed }
        let siValue = Int(u16(parts[si], 20))
        var size: UInt64 = 0, allocated: UInt64 = 0
        if let data = attrs.first(where: { $0.type == .data && $0.name == nil }) {
            size = data.realDataSize
            if case .nonResident(_, _, let reserved, _, _, _) = data.payload { allocated = reserved }
        }
        for (i, attr) in attrs.enumerated() where attr.type == .fileName {
            let value = Int(u16(parts[i], 20))
            for field in 0..<4 { put(u64(parts[si], siValue + field * 8), into: &parts[i], at: value + 8 + field * 8) }
            put(allocated, into: &parts[i], at: value + 40)
            put(size, into: &parts[i], at: value + 48)
        }
        return try rebuildRecord(fixed, attributes: parts, nextID: u16(fixed, 40), boot: boot)
    }

    /// Brings directory index entries up to date after deferred stream changes and returns
    /// unused append headroom to the volume.
    static func syncDirectoryEntry(volume original: NTFSVolume, recordNumber: UInt64) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let ctx = try MutationContext(original)
        let record = try ctx.editableRecord(recordNumber)
        var sealed = try ctx.fixed(record)
        sealed = sealRecord(sealed, boot: ctx.volume.bootSector)
        if !record.isDirectory, let data = record.defaultDataAttribute,
           case .nonResident(_, _, let allocated, let size, _, _) = data.payload,
           allocated > (size + ctx.cluster - 1) / ctx.cluster * ctx.cluster,
           let trimmed = try planStreamInPlace(ctx, record: record, offset: 0, data: Data(), size: size, touch: false) {
            sealed = trimmed
        }
        sealed = try refreshFileNames(sealed, boot: ctx.volume.bootSector)
        try ctx.stageRecord(recordNumber, sealed)
        try updateParentKeys(record: MFTRecord(recordNumber: recordNumber, rawData: sealed), context: ctx)
        try ctx.commit()
    }
}
