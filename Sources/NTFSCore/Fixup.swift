import Foundation

/// Handles NTFS Multi-Sector Header Update (Fixup Array) verification and restoration.
public enum FixupApplier {
    /// Applies fixups in-place to raw record data (MFT Record or INDX block).
    ///
    /// - Parameters:
    ///   - data: Mutable record data buffer.
    ///   - updateSequenceOffset: Offset to USA relative to record start.
    ///   - updateSequenceSize: Total number of 2-byte words in USA (1 header + 1 per sector).
    ///   - bytesPerSector: Sector size (usually 512).
    /// - Throws: `NTFSError.fixupVerificationFailed` or `NTFSError.outOfBounds`
    public static func applyFixup(
        data: inout Data,
        updateSequenceOffset: Int,
        updateSequenceSize: Int,
        bytesPerSector: Int = 512
    ) throws {
        guard updateSequenceSize > 0 else { return }

        let usaByteCount = updateSequenceSize * 2
        guard updateSequenceOffset + usaByteCount <= data.count else {
            throw NTFSError.outOfBounds(
                offset: UInt64(updateSequenceOffset),
                requested: usaByteCount,
                available: data.count
            )
        }

        let baseStart = data.startIndex

        // First 2-byte word is the update sequence number (USN)
        let usnOffset = baseStart + updateSequenceOffset
        let usn = UInt16(data[usnOffset]) | (UInt16(data[usnOffset + 1]) << 8)

        let numberOfSectors = updateSequenceSize - 1

        for i in 0..<numberOfSectors {
            let sectorEndOffset = (i + 1) * bytesPerSector - 2
            guard sectorEndOffset + 2 <= data.count else {
                break
            }

            // Read the signature currently at the end of the sector
            let currentSigOffset = baseStart + sectorEndOffset
            let currentSig = UInt16(data[currentSigOffset]) | (UInt16(data[currentSigOffset + 1]) << 8)

            guard currentSig == usn else {
                throw NTFSError.fixupVerificationFailed(
                    sectorIndex: i,
                    expected: usn,
                    found: currentSig
                )
            }

            // Restore the original 2 bytes from the USA array
            let savedValOffset = baseStart + updateSequenceOffset + ((i + 1) * 2)
            let savedByte0 = data[savedValOffset]
            let savedByte1 = data[savedValOffset + 1]

            data[currentSigOffset] = savedByte0
            data[currentSigOffset + 1] = savedByte1
        }
    }

    /// Prepares raw record data for writing by generating and applying the fixup array (USA/USN).
    ///
    /// - Parameters:
    ///   - data: Mutable record data buffer.
    ///   - updateSequenceOffset: Offset to USA relative to record start.
    ///   - updateSequenceSize: Total number of 2-byte words in USA (1 header + 1 per sector).
    ///   - usn: Update Sequence Number (default: 0x4242).
    ///   - bytesPerSector: Sector size (usually 512).
    public static func prepareForWrite(
        data: inout Data,
        updateSequenceOffset: Int,
        updateSequenceSize: Int,
        usn: UInt16 = 0x4242,
        bytesPerSector: Int = 512
    ) {
        guard updateSequenceSize > 0 else { return }
        let baseStart = data.startIndex
        let usnOffset = baseStart + updateSequenceOffset

        // 1. Write USN into USA header
        data[usnOffset] = UInt8(usn & 0xFF)
        data[usnOffset + 1] = UInt8((usn >> 8) & 0xFF)

        let numberOfSectors = updateSequenceSize - 1
        for i in 0..<numberOfSectors {
            let sectorEndOffset = (i + 1) * bytesPerSector - 2
            guard sectorEndOffset + 2 <= data.count else { break }

            let currentSigOffset = baseStart + sectorEndOffset
            let byte0 = data[currentSigOffset]
            let byte1 = data[currentSigOffset + 1]

            // 2. Save original sector tail into USA array
            let savedValOffset = baseStart + updateSequenceOffset + ((i + 1) * 2)
            data[savedValOffset] = byte0
            data[savedValOffset + 1] = byte1

            // 3. Overwrite sector tail with USN
            data[currentSigOffset] = UInt8(usn & 0xFF)
            data[currentSigOffset + 1] = UInt8((usn >> 8) & 0xFF)
        }
    }
}
