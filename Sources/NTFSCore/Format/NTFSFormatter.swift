import Foundation

/// Initializes NTFS 3.1 structures from documented on-disk formats.
/// The generated volume contains no executable boot loader and is not bootable.
public enum NTFSFormatter {
    public struct FormatOptions: Sendable {
        public let volumeName: String
        public let clusterSize: UInt32
        public let sectorSize: UInt16
        public init(volumeName: String = "UNTITLED", clusterSize: UInt32 = 4096, sectorSize: UInt16 = 512) {
            self.volumeName = volumeName.isEmpty ? "UNTITLED" : volumeName
            self.clusterSize = clusterSize
            self.sectorSize = sectorSize
        }
    }

    public static func format(device: BlockDevice, options: FormatOptions = FormatOptions()) throws {
        guard device.isWritable else { throw BlockDeviceError.readOnlyDevice }
        guard device.size >= 10 * 1024 * 1024 else {
            throw NTFSError.unsupportedFeature("NTFS requires at least 10 MiB")
        }
        let c = UInt64(options.clusterSize)
        guard options.sectorSize == 512, c >= 1024, c <= 65536, c & (c - 1) == 0,
              options.volumeName.utf16.count <= 32,
              !options.volumeName.unicodeScalars.contains(where: { $0.value < 32 || #"\/:*?"<>|"#.unicodeScalars.contains($0) }) else {
            throw NTFSError.unsupportedFeature("Invalid NTFS geometry or volume label")
        }
        // The final sector holds the backup VBR, outside the addressable cluster heap.
        let sectors = device.size / 512 - 1
        let clusters = sectors / (c / 512)
        func count(_ size: UInt64) -> UInt64 { (size + c - 1) / c }
        let bootCount = count(8192)
        let mftLCN = max(4, bootCount)
        let mftCount = count(112 * 1024)
        let mftSize = mftCount * c
        let bitmapLCN = mftLCN + mftCount
        let bitmapSize = ((clusters + 63) / 64) * 8
        let bitmapCount = count(bitmapSize)
        let upcase = upCaseTable()
        let upcaseLCN = max(40, bitmapLCN + bitmapCount)
        let upcaseCount = count(UInt64(upcase.count))
        let rootLCN = upcaseLCN + upcaseCount
        let rootCount = count(4096)
        let attrdef = attributeDefinitions()
        let attrdefLCN = rootLCN + rootCount
        let attrdefCount = count(UInt64(attrdef.count))
        let logLCN = attrdefLCN + attrdefCount
        let logSize: UInt64 = 2 * 1024 * 1024
        let logCount = count(logSize)
        let mirrorLCN = clusters / 2
        let mirrorSize = max(c, 4096)
        let mirrorCount = count(mirrorSize)
        guard logLCN + logCount < mirrorLCN, mirrorLCN + mirrorCount <= clusters else {
            throw NTFSError.unsupportedFeature("NTFS metadata does not fit the volume")
        }
        let serial = UInt64.random(in: 1...UInt64.max)
        let boot = bootSector(sectors: sectors, cluster: c, mft: mftLCN, mirror: mirrorLCN, serial: serial)
        var bitmap = Data(repeating: 0, count: Int(bitmapSize))
        for range in [UInt64(0)..<bootCount, mftLCN..<(mftLCN + mftCount),
                      bitmapLCN..<(bitmapLCN + bitmapCount), upcaseLCN..<(upcaseLCN + upcaseCount),
                      rootLCN..<(rootLCN + rootCount), attrdefLCN..<(attrdefLCN + attrdefCount),
                      logLCN..<(logLCN + logCount), mirrorLCN..<(mirrorLCN + mirrorCount)] {
            for bit in range { bitmap[Int(bit / 8)] |= 1 << UInt8(bit % 8) }
        }
        // Bits beyond the cluster heap must never be offered to an allocator.
        for bit in clusters..<(bitmapSize * 8) { bitmap[Int(bit / 8)] |= 1 << UInt8(bit % 8) }
        let timestamp = FileTimeConverter.toFileTime(date: Date())
        let names = ["$MFT", "$MFTMirr", "$LogFile", "$Volume", "$AttrDef", ".", "$Bitmap", "$Boot", "$BadClus", "$Secure", "$UpCase", "$Extend"]
        let sizes: [UInt64] = [mftSize, mirrorSize, logSize, 0, UInt64(attrdef.count), 0, bitmapSize, 8192, 0, 0, UInt64(upcase.count), 0]
        let allocations: [UInt64] = [mftSize, mirrorCount*c, logCount*c, 0, attrdefCount*c, 0, bitmapCount*c, bootCount*c, 0, 0, upcaseCount*c, 0]
        var filenames = [Data]()
        for n in 0..<12 {
            filenames.append(fileName(names[n], directory: n == 5 || n == 11, size: sizes[n],
                                      allocated: allocations[n], timestamp: timestamp))
        }
        func dataAttribute(_ lcn: UInt64, _ size: UInt64, id: UInt16 = 3) -> Data {
            nonresident(type: 0x80, lcn: lcn, clusterCount: count(size), size: size, allocated: count(size)*c, id: id)
        }
        var recordBitmap = Data(repeating: 0, count: Int(((mftSize / 1024 + 63) / 64) * 8))
        recordBitmap[0] = 0xff
        recordBitmap[1] = 0xff
        var records = Data()
        for n in 0..<Int(mftSize / 1024) {
            if n >= 16 {
                records.append(try record(number: n, attributes: [], used: false, directory: false))
                continue
            }
            var attrs = [resident(type: 0x10, value: standardInformation(timestamp: timestamp, directory: n == 5 || n == 11), id: 0)]
            if n < 12 { attrs.append(resident(type: 0x30, value: filenames[n], id: 1, indexed: true)) }
            attrs.append(resident(type: 0x50, value: securityDescriptor(), id: 2))
            switch n {
            case 0:
                attrs.append(dataAttribute(mftLCN, mftSize))
                attrs.append(resident(type: 0xb0, value: recordBitmap, id: 4))
            case 1: attrs.append(dataAttribute(mirrorLCN, mirrorSize))
            case 2: attrs.append(dataAttribute(logLCN, logSize))
            case 3:
                attrs.append(resident(type: 0x60, value: utf16(options.volumeName), id: 3))
                var info = Data(repeating: 0, count: 12); info[8] = 3; info[9] = 1
                attrs.append(resident(type: 0x70, value: info, id: 4))
                attrs.append(resident(type: 0x80, value: Data(), id: 5))
            case 4: attrs.append(dataAttribute(attrdefLCN, UInt64(attrdef.count)))
            case 5:
                attrs.append(resident(type: 0x90, name: "$I30", value: indexRoot(cluster: c, attributeType: 0x30, collation: 1, child: 0), id: 3))
                attrs.append(nonresident(type: 0xa0, name: "$I30", lcn: rootLCN, clusterCount: rootCount, size: 4096, allocated: rootCount*c, id: 4))
                attrs.append(resident(type: 0xb0, name: "$I30", value: Data([1,0,0,0,0,0,0,0]), id: 5))
            case 6: attrs.append(dataAttribute(bitmapLCN, bitmapSize))
            case 7: attrs.append(dataAttribute(0, 8192))
            case 8:
                attrs.append(resident(type: 0x80, value: Data(), id: 3))
                attrs.append(nonresident(type: 0x80, name: "$Bad", lcn: nil, clusterCount: clusters, size: clusters*c, allocated: clusters*c, initialized: 0, id: 4))
            case 9:
                attrs.append(resident(type: 0x80, name: "$SDS", value: Data(), id: 3))
                attrs.append(resident(type: 0x90, name: "$SDH", value: indexRoot(cluster: c, attributeType: 0, collation: 0x12), id: 4))
                attrs.append(resident(type: 0x90, name: "$SII", value: indexRoot(cluster: c, attributeType: 0, collation: 0x10), id: 5))
            case 10: attrs.append(dataAttribute(upcaseLCN, UInt64(upcase.count)))
            case 11: attrs.append(resident(type: 0x90, name: "$I30", value: indexRoot(cluster: c, attributeType: 0x30, collation: 1), id: 3))
            default: attrs.append(resident(type: 0x80, value: Data(), id: 3))
            }
            records.append(try record(number: n, attributes: attrs, used: true, directory: n == 5 || n == 11, links: n < 12 ? 1 : 0, viewIndex: n == 9))
        }
        var entries = Data()
        let sorted = names.indices.sorted { names[$0].uppercased() < names[$1].uppercased() }
        for n in sorted {
            let key = filenames[n]
            var e = Data(repeating: 0, count: align(16 + key.count))
            put(UInt64(n) | (UInt64(1) << 48), into: &e, at: 0)
            put(UInt16(e.count), into: &e, at: 8); put(UInt16(key.count), into: &e, at: 10)
            e.replaceSubrange(16..<(16 + key.count), with: key)
            entries.append(e)
        }
        entries.append(indexTerminator())
        var rootBlock = Data(repeating: 0, count: 4096)
        rootBlock.replaceSubrange(0..<4, with: Data("INDX".utf8))
        put(UInt16(40), into: &rootBlock, at: 4); put(UInt16(9), into: &rootBlock, at: 6)
        put(UInt32(40), into: &rootBlock, at: 24)
        put(UInt32(40 + entries.count), into: &rootBlock, at: 28)
        put(UInt32(4072), into: &rootBlock, at: 32)
        rootBlock.replaceSubrange(64..<(64 + entries.count), with: entries)
        fixup(&rootBlock, offset: 40)
        func writePadded(_ data: Data, lcn: UInt64, count: UInt64) throws {
            var padded = data
            padded.append(Data(repeating: 0, count: Int(count*c) - data.count))
            try device.write(offset: lcn*c, data: padded)
        }
        var bootStream = Data(repeating: 0, count: 8192)
        bootStream.replaceSubrange(0..<512, with: boot)
        try writePadded(bootStream, lcn: 0, count: bootCount)
        try device.write(offset: mftLCN*c, data: records)
        try writePadded(Data(records.prefix(Int(mirrorSize))), lcn: mirrorLCN, count: mirrorCount)
        try writePadded(bitmap, lcn: bitmapLCN, count: bitmapCount)
        try writePadded(upcase, lcn: upcaseLCN, count: upcaseCount)
        try writePadded(rootBlock, lcn: rootLCN, count: rootCount)
        try writePadded(attrdef, lcn: attrdefLCN, count: attrdefCount)
        // An all-ones journal is the documented uninitialized/empty log state.
        var journal = Data(repeating: 0xff, count: Int(logCount*c))
        let restart = logRestartPage(fileSize: logSize)
        journal.replaceSubrange(0..<4096, with: restart)
        journal.replaceSubrange(4096..<8192, with: restart)
        try device.write(offset: logLCN*c, data: journal)
        try device.write(offset: sectors*512, data: boot)
        try device.flush()
    }

    private static func align(_ n: Int) -> Int { (n + 7) & ~7 }
    private static func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
    private static func utf16(_ text: String) -> Data {
        var data = Data()
        for unit in text.utf16 { var little = unit.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        return data
    }
    private static func bootSector(sectors: UInt64, cluster: UInt64, mft: UInt64, mirror: UInt64, serial: UInt64) -> Data {
        var b = Data(repeating: 0, count: 512)
        b.replaceSubrange(0..<3, with: [0xeb, 0x52, 0x90])
        b.replaceSubrange(3..<11, with: Data("NTFS    ".utf8))
        put(UInt16(512), into: &b, at: 11); b[13] = UInt8(cluster / 512); b[21] = 0xf8
        put(UInt16(63), into: &b, at: 24); put(UInt16(255), into: &b, at: 26)
        put(sectors, into: &b, at: 40); put(mft, into: &b, at: 48); put(mirror, into: &b, at: 56)
        b[64] = 0xf6; b[68] = 0xf4
        put(serial, into: &b, at: 72); b[510] = 0x55; b[511] = 0xaa
        return b
    }
    private static func resident(type: UInt32, name: String = "", value: Data, id: UInt16, indexed: Bool = false) -> Data {
        let n = utf16(name), valueOffset = align(24 + n.count)
        var a = Data(repeating: 0, count: align(valueOffset + value.count))
        put(type, into: &a, at: 0); put(UInt32(a.count), into: &a, at: 4)
        a[9] = UInt8(n.count / 2); put(UInt16(n.isEmpty ? 0 : 24), into: &a, at: 10); put(id, into: &a, at: 14)
        put(UInt32(value.count), into: &a, at: 16); put(UInt16(valueOffset), into: &a, at: 20)
        a[22] = indexed ? 1 : 0
        a.replaceSubrange(24..<(24 + n.count), with: n)
        a.replaceSubrange(valueOffset..<(valueOffset + value.count), with: value)
        return a
    }
    private static func nonresident(type: UInt32, name: String = "", lcn: UInt64?, clusterCount: UInt64, size: UInt64, allocated: UInt64, initialized: UInt64? = nil, id: UInt16) -> Data {
        let n = utf16(name), runOffset = align(64 + n.count)
        let runs = DataRunEncoder.encode(runs: [DataRun(clusterCount: clusterCount, startingLCN: lcn)])
        var a = Data(repeating: 0, count: align(runOffset + runs.count))
        put(type, into: &a, at: 0); put(UInt32(a.count), into: &a, at: 4); a[8] = 1
        a[9] = UInt8(n.count / 2); put(UInt16(n.isEmpty ? 0 : 64), into: &a, at: 10); put(id, into: &a, at: 14)
        put(clusterCount - 1, into: &a, at: 24); put(UInt16(runOffset), into: &a, at: 32)
        put(allocated, into: &a, at: 40); put(size, into: &a, at: 48); put(initialized ?? size, into: &a, at: 56)
        a.replaceSubrange(64..<(64+n.count), with: n)
        a.replaceSubrange(runOffset..<(runOffset+runs.count), with: runs)
        return a
    }
    private static func standardInformation(timestamp: UInt64, directory: Bool) -> Data {
        var v = Data(repeating: 0, count: 48)
        for o in stride(from: 0, to: 32, by: 8) { put(timestamp, into: &v, at: o) }
        put(UInt32(directory ? 0x26 : 0x06), into: &v, at: 32)
        return v
    }
    private static func fileName(_ name: String, directory: Bool, size: UInt64, allocated: UInt64, timestamp: UInt64) -> Data {
        let n = utf16(name)
        var v = Data(repeating: 0, count: 66 + n.count)
        put(UInt64(5) | (UInt64(1) << 48), into: &v, at: 0)
        for o in stride(from: 8, to: 40, by: 8) { put(timestamp, into: &v, at: o) }
        put(allocated, into: &v, at: 40); put(size, into: &v, at: 48)
        put(UInt32(directory ? 0x10000006 : 0x06), into: &v, at: 56)
        v[64] = UInt8(n.count / 2); v[65] = 3
        v.replaceSubrange(66..<v.count, with: n)
        return v
    }
    /// A self-relative descriptor with SYSTEM owner, Administrators group, and
    /// an explicit null DACL. Permissions can subsequently be set by an NTFS host.
    private static func securityDescriptor() -> Data {
        var d = Data(repeating: 0, count: 48)
        d[0] = 1; put(UInt16(0x8004), into: &d, at: 2)
        put(UInt32(20), into: &d, at: 4); put(UInt32(32), into: &d, at: 8)
        d[20] = 1; d[21] = 1; d[27] = 5; put(UInt32(18), into: &d, at: 28)
        d[32] = 1; d[33] = 2; d[39] = 5; put(UInt32(32), into: &d, at: 40); put(UInt32(544), into: &d, at: 44)
        return d
    }
    private static func record(number: Int, attributes: [Data], used: Bool, directory: Bool, links: UInt16 = 0, viewIndex: Bool = false) throws -> Data {
        var r = Data(repeating: 0, count: 1024)
        r.replaceSubrange(0..<4, with: Data("FILE".utf8))
        put(UInt16(48), into: &r, at: 4); put(UInt16(3), into: &r, at: 6)
        put(UInt16(1), into: &r, at: 16); put(links, into: &r, at: 18)
        put(UInt16(56), into: &r, at: 20)
        put(UInt16((used ? 1 : 0) | (directory ? 2 : 0) | (viewIndex ? 8 : 0)), into: &r, at: 22)
        put(UInt32(1024), into: &r, at: 28); put(UInt16(attributes.count), into: &r, at: 40)
        put(UInt32(number), into: &r, at: 44)
        var offset = 56
        for a in attributes {
            guard offset + a.count + 8 <= 1024 else { throw NTFSError.unsupportedFeature("System MFT record exceeds capacity") }
            r.replaceSubrange(offset..<(offset + a.count), with: a); offset += a.count
        }
        put(UInt32.max, into: &r, at: offset); put(UInt32(offset+8), into: &r, at: 24)
        fixup(&r, offset: 48)
        return r
    }
    private static func fixup(_ data: inout Data, offset: Int) {
        put(UInt16(1), into: &data, at: offset)
        for i in 1...(data.count / 512) {
            let end = i*512-2
            data[offset+i*2] = data[end]; data[offset+i*2+1] = data[end+1]
            put(UInt16(1), into: &data, at: end)
        }
    }
    private static func indexTerminator(child: UInt64? = nil) -> Data {
        var e = Data(repeating: 0, count: child == nil ? 16 : 24)
        put(UInt16(e.count), into: &e, at: 8); put(UInt16(child == nil ? 2 : 3), into: &e, at: 12)
        if let child { put(child, into: &e, at: 16) }
        return e
    }
    private static func indexRoot(cluster: UInt64, attributeType: UInt32, collation: UInt32, child: UInt64? = nil) -> Data {
        let end = indexTerminator(child: child)
        var v = Data(repeating: 0, count: 32)
        put(attributeType, into: &v, at: 0); put(collation, into: &v, at: 4); put(UInt32(4096), into: &v, at: 8)
        // Index VCNs count sectors when a cluster is larger than an index block.
        v[12] = cluster <= 4096 ? UInt8(4096/cluster) : 8
        put(UInt32(16), into: &v, at: 16); put(UInt32(16+end.count), into: &v, at: 20); put(UInt32(16+end.count), into: &v, at: 24)
        v[28] = child == nil ? 0 : 1; v.append(end)
        return v
    }
    /// LFS 1.1 restart pages, marked clean with a single NTFS client and no LSN.
    /// Field layouts: Linux-NTFS $LogFile documentation.
    private static func logRestartPage(fileSize: UInt64) -> Data {
        var p = Data(repeating: 0, count: 4096)
        p.replaceSubrange(0..<4, with: Data("RSTR".utf8))
        put(UInt16(32), into: &p, at: 4); put(UInt16(9), into: &p, at: 6)
        put(UInt32(4096), into: &p, at: 16); put(UInt32(4096), into: &p, at: 20)
        put(UInt16(56), into: &p, at: 24)
        put(UInt16(1), into: &p, at: 26); put(UInt16(1), into: &p, at: 28)
        let area = 56
        put(UInt16(1), into: &p, at: area+8)
        put(UInt16.max, into: &p, at: area+10)
        put(UInt16(0), into: &p, at: area+12)
        put(UInt16(2), into: &p, at: area+14)
        let fileSizeBits = 64 - fileSize.leadingZeroBitCount
        put(UInt32(64 - (fileSizeBits - 3)), into: &p, at: area+16)
        put(UInt16(208), into: &p, at: area+20); put(UInt16(48), into: &p, at: area+22)
        put(fileSize, into: &p, at: area+24)
        put(UInt16(48), into: &p, at: area+36); put(UInt16(64), into: &p, at: area+38)
        let client = area+48
        put(UInt16.max, into: &p, at: client+16); put(UInt16.max, into: &p, at: client+18)
        let name = utf16("NTFS")
        put(UInt32(name.count), into: &p, at: client+28)
        p.replaceSubrange((client+32)..<(client+32+name.count), with: name)
        fixup(&p, offset: 32)
        return p
    }
    private static func attributeDefinitions() -> Data {
        // Linux-NTFS documentation: 160-byte rows; NTFS 3.1 attribute types.
        let rows: [(String, UInt32, UInt32, UInt64, UInt64)] = [
            ("$STANDARD_INFORMATION",0x10,0x40,48,72), ("$ATTRIBUTE_LIST",0x20,0x80,0,UInt64.max),
            ("$FILE_NAME",0x30,0x42,68,578), ("$OBJECT_ID",0x40,0x40,0,256),
            ("$SECURITY_DESCRIPTOR",0x50,0x80,0,UInt64.max), ("$VOLUME_NAME",0x60,0x40,2,256),
            ("$VOLUME_INFORMATION",0x70,0x40,12,12), ("$DATA",0x80,0,0,UInt64.max),
            ("$INDEX_ROOT",0x90,0x40,0,UInt64.max), ("$INDEX_ALLOCATION",0xa0,0x80,0,UInt64.max),
            ("$BITMAP",0xb0,0x80,0,UInt64.max), ("$REPARSE_POINT",0xc0,0x80,0,16384),
            ("$EA_INFORMATION",0xd0,0x40,8,8), ("$EA",0xe0,0,0,65536),
            ("$LOGGED_UTILITY_STREAM",0x100,0x80,0,65536)]
        var d = Data()
        for (name,type,flags,min,max) in rows {
            var row = Data(repeating: 0, count: 160)
            let label = utf16(name); row.replaceSubrange(0..<label.count, with: label)
            put(type, into: &row, at: 128); put(flags, into: &row, at: 140)
            put(min, into: &row, at: 144); put(max, into: &row, at: 152); d.append(row)
        }
        d.append(Data(repeating: 0, count: 160)); return d
    }
    private static func upCaseTable() -> Data {
        var table = Data(capacity: 131072)
        for unit in UInt32(0)...0xffff {
            var mapped = UInt16(unit)
            if let scalar = Unicode.Scalar(unit) {
                let uppercase = Array(String(scalar).uppercased().utf16)
                if uppercase.count == 1 { mapped = uppercase[0] }
            }
            var le = mapped.littleEndian; withUnsafeBytes(of: &le) { table.append(contentsOf: $0) }
        }
        return table
    }
}
