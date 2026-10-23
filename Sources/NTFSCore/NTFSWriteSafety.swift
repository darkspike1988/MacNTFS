import Foundation

/// State of the NTFS journal. Windows replays unfinished log records at its next mount and
/// could overwrite unjournaled changes made here, so writing requires an empty or clean log.
/// A clean log is left untouched: it holds nothing to replay, and Windows and independent
/// checkers accept it as is (an all-0xFF log makes them reinitialize it).
public enum NTFSJournalState: Equatable, Sendable {
    /// Every restart page is 0xFF; Windows reinitializes the log.
    case empty
    /// All log clients finished; nothing remains to replay.
    case clean
    case unclean(String)
}

extension NTFSVolume {
    /// Reads the $LogFile restart pages. Layout: the restart page header and restart area
    /// as described by the Linux-NTFS documentation of $LogFile.
    public func journalState() throws -> NTFSJournalState {
        let record = try resolvedRecord(readMFTRecord(number: 2))
        guard let attr = record.defaultDataAttribute, attr.flags.isEmpty else {
            return .unclean("$LogFile has no readable data stream")
        }
        let size = attr.realDataSize
        guard size >= 8192 else { return .unclean("$LogFile is too small") }
        let head = try readData(record: record, offset: 0, length: 8192)
        if head.allSatisfy({ $0 == 0xFF }) { return .empty }

        var newest: (lsn: UInt64, clean: Bool)?
        var candidates: [UInt64] = [0]
        while let offset = candidates.first {
            candidates.removeFirst()
            let probe = try readData(record: record, offset: offset, length: 512)
            guard probe.count == 512, let magic = String(data: probe.prefix(4), encoding: .ascii),
                  magic == "RSTR" || magic == "CHKD" else {
                if offset == 0 { candidates.append(4096) }
                continue
            }
            let pageSize = Int(NTFSVolumeWriter.u32(probe, 16))
            guard pageSize >= 512, pageSize <= 65536, pageSize.nonzeroBitCount == 1, UInt64(pageSize) * 2 <= size else {
                continue
            }
            if offset == 0 { candidates.append(UInt64(pageSize)) }
            var page = try readData(record: record, offset: offset, length: pageSize)
            let usaOffset = Int(NTFSVolumeWriter.u16(page, 4)), usaCount = Int(NTFSVolumeWriter.u16(page, 6))
            guard usaCount == pageSize / 512 + 1,
                  (try? FixupApplier.applyFixup(data: &page, updateSequenceOffset: usaOffset,
                                                 updateSequenceSize: usaCount, bytesPerSector: 512)) != nil else {
                continue
            }
            let area = Int(NTFSVolumeWriter.u16(page, 24))
            guard area >= 30, area % 8 == 0, area + 16 <= pageSize else { continue }
            let lsn = NTFSVolumeWriter.u64(page, area)
            let inUse = NTFSVolumeWriter.u16(page, area + 12)
            let flags = NTFSVolumeWriter.u16(page, area + 14)
            let clean = inUse == 0xFFFF || flags & 0x0002 != 0
            if newest == nil || lsn > newest!.lsn { newest = (lsn, clean) }
        }
        guard let newest else { return .unclean("$LogFile has no valid restart page") }
        return newest.clean ? .clean : .unclean("Windows did not finish its NTFS journal")
    }
}

extension NTFSVolumeWriter {
    /// Returns why writing is unsafe, or nil when the volume may be modified.
    /// Mirrors the checks that make NTFS-3G-based drivers fall back to read-only.
    public static func writeSafetyIssue(_ volume: NTFSVolume) -> String? {
        do {
            let status = try volume.readMFTRecord(number: 3)
            guard let info = status.attribute(ofType: .volumeInformation)?.residentData, info.count >= 12 else {
                return "The NTFS volume status is unreadable"
            }
            if u16(info, 10) & 1 != 0 { return "Windows marked the volume dirty; run chkdsk on Windows" }
            let mft = try volume.readMFTRecord(number: 0)
            if mft.attribute(ofType: .attributeList) != nil {
                return "The $MFT uses extension records; writing it is not supported yet"
            }
            if case .unclean(let reason) = try volume.journalState() {
                return reason + "; shut Windows down fully (no hibernation or Fast Startup)"
            }
            if let hiberfil = try? volume.lookup(path: "/hiberfil.sys"), !hiberfil.isDirectory {
                let header = try volume.readData(record: hiberfil.record, offset: 0, length: 4096)
                guard header.count >= 4, header.prefix(4).allSatisfy({ $0 == 0 }) else {
                    return "Windows is hibernated; resume and shut it down fully (no Fast Startup)"
                }
            }
            return nil
        } catch {
            return "The NTFS volume state could not be verified: \(error.localizedDescription)"
        }
    }

    /// Run under `writeLock` before planning a change.
    static func prepareForWriting(_ volume: NTFSVolume) throws {
        guard volume.blockDevice.isWritable else { throw BlockDeviceError.readOnlyDevice }
        if let issue = writeSafetyIssue(volume) { throw NTFSError.unsupportedFeature(issue) }
    }

    /// Clears the "volume is dirty" bit in $Volume and its $MFTMirr copy.
    public static func clearDirtyFlag(_ volume: NTFSVolume) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard volume.blockDevice.isWritable else { throw BlockDeviceError.readOnlyDevice }
        let cluster = UInt64(volume.bootSector.clusterSizeBytes)
        let size = UInt64(volume.bootSector.mftRecordSizeBytes)
        var record = try fixedRecord(readRuns(volume.mftRecordRuns, offset: 3 * size, count: Int(size),
                                              cluster: cluster, device: volume.blockDevice),
                                     boot: volume.bootSector)
        let offset = try attributeOffset(type: 0x70, name: nil, record: record)
        let flags = offset + Int(u16(record, offset + 20)) + 10
        put(u16(record, flags) & ~1, into: &record, at: flags)
        let tx = WriteTransaction(device: volume.blockDevice)
        let sealed = sealRecord(record, boot: volume.bootSector)
        try stageRuns(volume.mftRecordRuns, offset: 3 * size, data: sealed, cluster: cluster, tx: tx)
        let mirror = try volume.readMFTRecord(number: 1)
        if let attr = mirror.defaultDataAttribute, let runs = attr.runs, 4 * size <= attr.realDataSize {
            try stageRuns(runs, offset: 3 * size, data: sealed, cluster: cluster, tx: tx)
        }
        try tx.commit()
    }
}
