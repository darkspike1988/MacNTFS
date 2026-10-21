import Foundation

/// Constructs valid NTFS 1024-byte MFT records with fixup array calculations.
public enum MFTRecordBuilder {
    /// Builds a complete 1024-byte MFT record for a regular file.
    public static func buildFileRecord(
        recordNumber: UInt64,
        sequenceNumber: UInt16 = 1,
        parentDirectoryRecordNumber: UInt64 = 5,
        fileName: String,
        fileContent: Data,
        creationDate: Date = Date(),
        modificationDate: Date = Date()
    ) throws -> Data {
        var record = Data(repeating: 0, count: 1024)

        // 1. Write Header placeholder
        let usaOffset: UInt16 = 0x30 // 48
        let usaSize: UInt16 = 3      // 1 USN + 2 sectors
        let firstAttrOffset: UInt16 = 0x38 // 56 bytes

        var headerData = Data()
        headerData.append(contentsOf: [0x46, 0x49, 0x4C, 0x45]) // "FILE"
        headerData.append(contentsOf: withUnsafeBytes(of: usaOffset.littleEndian) { Array($0) })
        headerData.append(contentsOf: withUnsafeBytes(of: usaSize.littleEndian) { Array($0) })
        headerData.append(contentsOf: [UInt8](repeating: 0, count: 8)) // $LogFile LSN = 0
        headerData.append(contentsOf: withUnsafeBytes(of: sequenceNumber.littleEndian) { Array($0) })
        headerData.append(contentsOf: [0x01, 0x00]) // Hard link count = 1
        headerData.append(contentsOf: withUnsafeBytes(of: firstAttrOffset.littleEndian) { Array($0) })
        headerData.append(contentsOf: [0x01, 0x00]) // Flags = In Use (0x0001)

        // Used size & Allocated size placeholders (fill later)
        headerData.append(contentsOf: [UInt8](repeating: 0, count: 8))
        // Base record ref = 0 (8 bytes)
        headerData.append(contentsOf: [UInt8](repeating: 0, count: 8))
        // Next attribute ID = 4 (2 bytes)
        headerData.append(contentsOf: [0x04, 0x00])
        // Reserved (2 bytes)
        headerData.append(contentsOf: [0x00, 0x00])
        // Record number (4 bytes)
        let recNum32 = UInt32(truncatingIfNeeded: recordNumber).littleEndian
        headerData.append(contentsOf: withUnsafeBytes(of: recNum32) { Array($0) })

        record.replaceSubrange(0..<headerData.count, with: headerData)

        // 2. Build Attributes starting at firstAttrOffset (0x38)
        var attrOffset = Int(firstAttrOffset)

        // --- $STANDARD_INFORMATION (0x10) ---
        let stdInfoAttr = buildStandardInfoAttribute(
            creationDate: creationDate,
            modificationDate: modificationDate,
            attributeID: 0
        )
        record.replaceSubrange(attrOffset..<(attrOffset + stdInfoAttr.count), with: stdInfoAttr)
        attrOffset += stdInfoAttr.count

        // --- $FILE_NAME (0x30) ---
        let fnAttr = buildFileNameAttribute(
            parentRecord: parentDirectoryRecordNumber,
            name: fileName,
            fileSize: UInt64(fileContent.count),
            creationDate: creationDate,
            modificationDate: modificationDate,
            attributeID: 1
        )
        record.replaceSubrange(attrOffset..<(attrOffset + fnAttr.count), with: fnAttr)
        attrOffset += fnAttr.count

        // --- $DATA (0x80) (Resident) ---
        let dataAttr = buildResidentDataAttribute(content: fileContent, attributeID: 2)
        guard attrOffset + dataAttr.count + 8 <= 1020 else {
            throw NTFSError.unsupportedFeature("File size exceeds resident MFT capacity; non-resident write required")
        }
        record.replaceSubrange(attrOffset..<(attrOffset + dataAttr.count), with: dataAttr)
        attrOffset += dataAttr.count

        // --- End Marker (0xFFFFFFFF) ---
        let endMarker: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]
        record.replaceSubrange(attrOffset..<(attrOffset + endMarker.count), with: endMarker)
        attrOffset += endMarker.count

        // Update Used Size (offset 0x18) and Allocated Size (offset 0x1C)
        var usedSize = UInt32(attrOffset).littleEndian
        var allocSize = UInt32(1024).littleEndian
        withUnsafeBytes(of: &usedSize) { record.replaceSubrange(0x18..<0x1C, with: $0) }
        withUnsafeBytes(of: &allocSize) { record.replaceSubrange(0x1C..<0x20, with: $0) }

        // 3. Calculate and apply Fixup Array (USA)
        let usn: UInt16 = 0x4242 // Update Sequence Number

        // Save original sector tails:
        // Sector 0 end: bytes 510..511
        // Sector 1 end: bytes 1022..1023
        let sec0Byte0 = record[510]
        let sec0Byte1 = record[511]
        let sec1Byte0 = record[1022]
        let sec1Byte1 = record[1023]

        // Write USA into header at usaOffset (0x30)
        let uOffset = Int(usaOffset)
        record[uOffset] = UInt8(usn & 0xFF)
        record[uOffset + 1] = UInt8((usn >> 8) & 0xFF)
        record[uOffset + 2] = sec0Byte0
        record[uOffset + 3] = sec0Byte1
        record[uOffset + 4] = sec1Byte0
        record[uOffset + 5] = sec1Byte1

        // Replace sector tails with USN
        record[510] = UInt8(usn & 0xFF)
        record[511] = UInt8((usn >> 8) & 0xFF)
        record[1022] = UInt8(usn & 0xFF)
        record[1023] = UInt8((usn >> 8) & 0xFF)

        return record
    }

    private static func buildStandardInfoAttribute(
        creationDate: Date,
        modificationDate: Date,
        attributeID: UInt16
    ) -> Data {
        var value = Data()
        var cTime = FileTimeConverter.toFileTime(date: creationDate).littleEndian
        var mTime = FileTimeConverter.toFileTime(date: modificationDate).littleEndian
        var dosFlags: UInt32 = 0x20 // ARCHIVE

        withUnsafeBytes(of: &cTime) { value.append(contentsOf: $0) } // Creation
        withUnsafeBytes(of: &mTime) { value.append(contentsOf: $0) } // Modification
        withUnsafeBytes(of: &mTime) { value.append(contentsOf: $0) } // MFT Modification
        withUnsafeBytes(of: &mTime) { value.append(contentsOf: $0) } // Access
        withUnsafeBytes(of: &dosFlags) { value.append(contentsOf: $0) } // DOS Flags
        value.append(contentsOf: [UInt8](repeating: 0, count: 16)) // Max versions etc.

        return wrapResidentAttribute(type: 0x10, value: value, attributeID: attributeID)
    }

    private static func buildFileNameAttribute(
        parentRecord: UInt64,
        name: String,
        fileSize: UInt64,
        creationDate: Date,
        modificationDate: Date,
        attributeID: UInt16
    ) -> Data {
        var value = Data()

        // 48-bit parent record + 16-bit sequence (e.g. seq 1)
        var rawParentRef = (parentRecord & 0x0000_FFFF_FFFF_FFFF) | (UInt64(1) << 48)
        var cTime = FileTimeConverter.toFileTime(date: creationDate).littleEndian
        var mTime = FileTimeConverter.toFileTime(date: modificationDate).littleEndian
        var allocSize = (fileSize).littleEndian
        var realSize = (fileSize).littleEndian
        var flags: UInt32 = 0x20 // ARCHIVE

        withUnsafeBytes(of: &rawParentRef) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &cTime) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &mTime) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &mTime) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &mTime) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &allocSize) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &realSize) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { value.append(contentsOf: $0) }
        value.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Reparse / EA

        let utf16Chars = Array(name.utf16)
        value.append(UInt8(utf16Chars.count)) // Name length
        value.append(0x03) // Win32 & DOS namespace

        for char in utf16Chars {
            var le = char.littleEndian
            withUnsafeBytes(of: &le) { value.append(contentsOf: $0) }
        }

        return wrapResidentAttribute(type: 0x30, value: value, attributeID: attributeID)
    }

    private static func buildResidentDataAttribute(content: Data, attributeID: UInt16) -> Data {
        return wrapResidentAttribute(type: 0x80, value: content, attributeID: attributeID)
    }

    private static func wrapResidentAttribute(type: UInt32, value: Data, attributeID: UInt16) -> Data {
        let headerSize = 24 // Resident attribute header size
        let unalignedTotal = headerSize + value.count
        let alignedTotal = (unalignedTotal + 7) & ~7 // Align to 8 bytes

        var result = Data()
        var rawType = type.littleEndian
        var recordLength = UInt32(alignedTotal).littleEndian
        let nonResident: UInt8 = 0
        let nameLength: UInt8 = 0
        var nameOffset: UInt16 = 0
        var flags: UInt16 = 0
        var attrID = attributeID.littleEndian
        var valueLength = UInt32(value.count).littleEndian
        var valueOffset = UInt16(headerSize).littleEndian
        let indexed: UInt8 = 0
        let padding: UInt8 = 0

        withUnsafeBytes(of: &rawType) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &recordLength) { result.append(contentsOf: $0) }
        result.append(nonResident)
        result.append(nameLength)
        withUnsafeBytes(of: &nameOffset) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &attrID) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &valueLength) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: &valueOffset) { result.append(contentsOf: $0) }
        result.append(indexed)
        result.append(padding)

        result.append(value)

        // Pad with zeros to 8-byte alignment
        let padCount = alignedTotal - unalignedTotal
        if padCount > 0 {
            result.append(contentsOf: [UInt8](repeating: 0, count: padCount))
        }

        return result
    }
}
