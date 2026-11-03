import Foundation

/// Handles NTFS Multi-Sector Header Update (Fixup Array) verification and restoration.
public enum FixupApplier {
    /// NTFS multi-sector protection works on 512-byte blocks on every volume,
    /// whatever the sector size of the device is.
    public static let blockSize = 512

    /// Applies fixups in-place to raw record data (MFT Record or INDX block).
    ///
    /// - Parameters:
    ///   - data: Mutable record data buffer.
    ///   - updateSequenceOffset: Offset to USA relative to record start.
    ///   - updateSequenceSize: Total number of 2-byte words in USA (1 header + 1 per 512-byte block).
    /// - Throws: `NTFSError.fixupVerificationFailed` or `NTFSError.outOfBounds`
    public static func applyFixup(
        data: inout Data,
        updateSequenceOffset: Int,
        updateSequenceSize: Int
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

        let numberOfBlocks = updateSequenceSize - 1
        guard numberOfBlocks <= data.count / blockSize else {
            throw NTFSError.outOfBounds(
                offset: UInt64(updateSequenceOffset),
                requested: numberOfBlocks * blockSize,
                available: data.count
            )
        }

        for i in 0..<numberOfBlocks {
            let blockEndOffset = (i + 1) * blockSize - 2

            // Read the signature currently at the end of the block
            let currentSigOffset = baseStart + blockEndOffset
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
            data[currentSigOffset] = data[savedValOffset]
            data[currentSigOffset + 1] = data[savedValOffset + 1]
        }
    }
}
