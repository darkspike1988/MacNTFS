import Foundation

/// Represents the NTFS Volume Boot Record (VBR) located at sector 0.
public struct BootSector: Sendable {
    public let oemID: String
    public let bytesPerSector: UInt16
    public let sectorsPerCluster: UInt8
    public let totalSectors: UInt64
    public let mftClusterNumber: UInt64
    public let mftMirrorClusterNumber: UInt64
    public let mftRecordSizeBytes: UInt32
    public let indexRecordSizeBytes: UInt32
    public let volumeSerialNumber: UInt64

    public var clusterSizeBytes: UInt32 {
        UInt32(bytesPerSector) * UInt32(sectorsPerCluster)
    }

    public var totalSizeBytes: UInt64 {
        totalSectors * UInt64(bytesPerSector)
    }

    public var mftByteOffset: UInt64 {
        mftClusterNumber * UInt64(clusterSizeBytes)
    }

    public init(data: Data) throws {
        guard data.count >= 512 else {
            throw NTFSError.invalidBootSector("Data size must be at least 512 bytes, got \(data.count)")
        }

        var reader = BinaryReader(data: data)

        // Verify boot signature at offset 510 (0x1FE)
        let sig0 = data[data.startIndex + 510]
        let sig1 = data[data.startIndex + 511]
        guard sig0 == 0x55 && sig1 == 0xAA else {
            throw NTFSError.invalidBootSector("Invalid boot signature at 0x1FE: \(String(format: "%02X %02X", sig0, sig1))")
        }

        // Jump instruction (3 bytes)
        try reader.skip(3)

        // OEM ID (8 bytes ASCII, must be "NTFS    ")
        let oem = try reader.readASCIIString(byteCount: 8)
        guard oem == "NTFS    " else {
            throw NTFSError.invalidBootSector("Invalid OEM ID: '\(oem)'. Expected 'NTFS    '")
        }
        self.oemID = oem

        // Bytes per sector (offset 0x0B)
        self.bytesPerSector = try reader.readUInt16()
        guard self.bytesPerSector >= 512 && (self.bytesPerSector & (self.bytesPerSector - 1)) == 0 else {
            throw NTFSError.invalidBootSector("Invalid bytes per sector: \(self.bytesPerSector)")
        }

        // Sectors per cluster (offset 0x0D)
        self.sectorsPerCluster = try reader.readUInt8()
        guard self.sectorsPerCluster > 0 && (self.sectorsPerCluster & (self.sectorsPerCluster - 1)) == 0 else {
            throw NTFSError.invalidBootSector("Invalid sectors per cluster: \(self.sectorsPerCluster)")
        }

        // Skip to offset 0x28 (total sectors)
        // From 0x0E to 0x28 is 26 bytes
        try reader.skip(26)
        self.totalSectors = try reader.readUInt64()

        // MFT cluster number (offset 0x30)
        self.mftClusterNumber = try reader.readUInt64()

        // MFT Mirror cluster number (offset 0x38)
        self.mftMirrorClusterNumber = try reader.readUInt64()

        // Clusters per MFT Record (offset 0x40)
        let rawMftRecordVal = try reader.readUInt8()
        let signedMftVal = Int8(bitPattern: rawMftRecordVal)
        if signedMftVal < 0 {
            // Negative value represents 2^(-val) bytes (e.g. 0xF6 is -10 -> 2^10 = 1024 bytes)
            self.mftRecordSizeBytes = 1 << UInt32(-signedMftVal)
        } else {
            self.mftRecordSizeBytes = UInt32(signedMftVal) * UInt32(self.bytesPerSector) * UInt32(self.sectorsPerCluster)
        }

        // Skip 3 reserved bytes (0x41 - 0x43)
        try reader.skip(3)

        // Clusters per Index Record (offset 0x44)
        let rawIndexRecordVal = try reader.readUInt8()
        let signedIndexVal = Int8(bitPattern: rawIndexRecordVal)
        if signedIndexVal < 0 {
            self.indexRecordSizeBytes = 1 << UInt32(-signedIndexVal)
        } else {
            self.indexRecordSizeBytes = UInt32(signedIndexVal) * UInt32(self.bytesPerSector) * UInt32(self.sectorsPerCluster)
        }

        // Skip 3 reserved bytes (0x45 - 0x47)
        try reader.skip(3)

        // Volume Serial Number (offset 0x48)
        self.volumeSerialNumber = try reader.readUInt64()
    }
}
