import Foundation
@testable import NTFSCore

/// Test helpers around the committed fixture image `Tests/Fixtures/mini.img`,
/// a small volume written by ntfs-3g (see scripts/corpus and Tests/Corpus/README.md).
enum Fixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func miniImage() throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("mini.img"))
    }

    static func put64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        for i in 0..<8 { data[offset + i] = UInt8((value >> UInt64(8 * i)) & 0xFF) }
    }

    /// Byte offset on the device of an MFT record.
    static func diskOffset(ofRecord number: UInt64, in volume: NTFSVolume) -> Int {
        let recordSize = UInt64(volume.bootSector.mftRecordSizeBytes)
        let clusterSize = UInt64(volume.bootSector.clusterSizeBytes)
        var position = number * recordSize
        var runStart: UInt64 = 0
        for run in volume.mftRecordRuns {
            let runBytes = run.clusterCount * clusterSize
            if position < runStart + runBytes, let lcn = run.startingLCN {
                return Int(lcn * clusterSize + (position - runStart))
            }
            runStart += runBytes
        }
        fatalError("MFT record \(number) is not mapped")
    }

    static func miniAttributeListImage() throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("mini-attrlist.img"))
    }

    /// The offset inside the record of the first attribute of `type`, or nil.
    static func attributeOffset(type wanted: UInt32, in image: Data, recordOffset: Int) -> Int? {
        var offset = Int(image[recordOffset + 0x14]) | (Int(image[recordOffset + 0x15]) << 8)
        while offset + 8 <= 1024 {
            let at = recordOffset + offset
            let type = UInt32(image[at]) | (UInt32(image[at + 1]) << 8) | (UInt32(image[at + 2]) << 16) | (UInt32(image[at + 3]) << 24)
            if type == 0xFFFF_FFFF { return nil }
            let length = Int(image[at + 4]) | (Int(image[at + 5]) << 8)
            if type == wanted && image[at + 9] == 0 /* unnamed */ { return offset }
            guard length > 0 else { return nil }
            offset += length
        }
        return nil
    }

    /// A copy of an image after `patch` changed the raw MFT record of `path`.
    /// `patch` gets the image, the byte offset of the record, the offset of its first attribute and the
    /// offset of its unnamed $DATA attribute (or -1). Patch only headers, never the last two bytes of a
    /// 512-byte block, because those hold the update sequence number.
    static func patchedImage(
        _ original: Data,
        path: String,
        patch: (inout Data, _ recordOffset: Int, _ firstAttribute: Int, _ dataAttribute: Int) -> Void
    ) throws -> Data {
        var image = original
        let volume = try NTFSVolume(blockDevice: MemoryBlockDevice(data: image))
        let record = try volume.lookup(path: path).record
        let recordOffset = diskOffset(ofRecord: record.recordNumber, in: volume)
        let first = Int(image[recordOffset + 0x14]) | (Int(image[recordOffset + 0x15]) << 8)
        let dataAttribute = attributeOffset(type: 0x80, in: image, recordOffset: recordOffset) ?? -1
        patch(&image, recordOffset, first, dataAttribute)
        return image
    }

    /// Returns a volume over a copy of the mini image after `patch` changed the raw MFT record of `path`.
    static func patchedVolume(
        path: String,
        patch: (inout Data, _ recordOffset: Int, _ firstAttribute: Int, _ dataAttribute: Int) -> Void
    ) throws -> NTFSVolume {
        let image = try patchedImage(try miniImage(), path: path, patch: patch)
        return try NTFSVolume(blockDevice: MemoryBlockDevice(data: image))
    }
}
