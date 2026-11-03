import Foundation

/// Represents the NTFS Volume Boot Record (VBR) located at sector 0.
/// Every value is range-checked, because the sector comes from an untrusted disk.
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

        // Bytes per sector (offset 0x0B): NTFS supports 512 to 4096
        let sectorSize = try reader.readUInt16()
        guard sectorSize >= 512 && sectorSize <= 4096 && (sectorSize & (sectorSize - 1)) == 0 else {
            throw NTFSError.invalidBootSector("Invalid bytes per sector: \(sectorSize)")
        }
        self.bytesPerSector = sectorSize

        // Sectors per cluster (offset 0x0D): powers of two up to 128
        let perCluster = try reader.readUInt8()
        guard perCluster > 0 && (perCluster & (perCluster - 1)) == 0 else {
            throw NTFSError.invalidBootSector("Invalid sectors per cluster: \(perCluster)")
        }
        self.sectorsPerCluster = perCluster
        let clusterSize = UInt64(sectorSize) * UInt64(perCluster)

        // Skip to offset 0x28 (total sectors)
        // From 0x0E to 0x28 is 26 bytes
        try reader.skip(26)
        let sectors = try reader.readUInt64()
        let (totalBytes, sizeOverflow) = sectors.multipliedReportingOverflow(by: UInt64(sectorSize))
        guard sectors > 0 && !sizeOverflow else {
            throw NTFSError.invalidBootSector("Invalid total sector count: \(sectors)")
        }
        self.totalSectors = sectors

        // MFT cluster number (offset 0x30) must start inside the volume
        let mftCluster = try reader.readUInt64()
        let (mftOffset, mftOverflow) = mftCluster.multipliedReportingOverflow(by: clusterSize)
        guard !mftOverflow && mftOffset < totalBytes else {
            throw NTFSError.invalidBootSector("MFT cluster \(mftCluster) lies outside the volume")
        }
        self.mftClusterNumber = mftCluster

        // MFT Mirror cluster number (offset 0x38)
        self.mftMirrorClusterNumber = try reader.readUInt64()

        // Clusters per MFT Record (offset 0x40)
        self.mftRecordSizeBytes = try BootSector.decodeRecordSize(
            try reader.readUInt8(), clusterSize: clusterSize, name: "MFT record", allowed: 1024...65536
        )

        // Skip 3 reserved bytes (0x41 - 0x43)
        try reader.skip(3)

        // Clusters per Index Record (offset 0x44)
        self.indexRecordSizeBytes = try BootSector.decodeRecordSize(
            try reader.readUInt8(), clusterSize: clusterSize, name: "index record", allowed: 512...65536
        )

        // Skip 3 reserved bytes (0x45 - 0x47)
        try reader.skip(3)

        // Volume Serial Number (offset 0x48)
        self.volumeSerialNumber = try reader.readUInt64()
    }

    /// A positive value counts clusters. A negative value `-n` means 2^n bytes.
    private static func decodeRecordSize(
        _ raw: UInt8,
        clusterSize: UInt64,
        name: String,
        allowed: ClosedRange<UInt64>
    ) throws -> UInt32 {
        let signed = Int(Int8(bitPattern: raw))
        let size: UInt64
        if signed < 0 {
            let shift = -signed
            guard shift <= 16 else {
                throw NTFSError.invalidBootSector("Invalid \(name) size exponent: -\(shift)")
            }
            size = UInt64(1) << UInt64(shift)
        } else {
            let (bytes, overflow) = UInt64(signed).multipliedReportingOverflow(by: clusterSize)
            guard !overflow else {
                throw NTFSError.invalidBootSector("Invalid \(name) size: \(signed) clusters")
            }
            size = bytes
        }
        guard allowed.contains(size) && (size & (size - 1)) == 0 else {
            throw NTFSError.invalidBootSector("Unsupported \(name) size: \(size) bytes")
        }
        return UInt32(size)
    }
}
