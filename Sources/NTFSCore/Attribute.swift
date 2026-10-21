import Foundation

public struct AttributeHeaderFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let compressed = AttributeHeaderFlags(rawValue: 0x0001)
    public static let encrypted  = AttributeHeaderFlags(rawValue: 0x4000)
    public static let sparse     = AttributeHeaderFlags(rawValue: 0x8000)
}

public enum AttributeData: Sendable {
    case resident(Data)
    case nonResident(
        startingVCN: UInt64,
        endingVCN: UInt64,
        allocatedSize: UInt64,
        realSize: UInt64,
        initializedSize: UInt64,
        runs: [DataRun]
    )
}

public struct NTFSAttribute: Sendable {
    public let type: AttributeType
    public let recordLength: UInt32
    public let isNonResident: Bool
    public let name: String?
    public let flags: AttributeHeaderFlags
    public let attributeID: UInt16
    public let payload: AttributeData

    public var residentData: Data? {
        if case .resident(let data) = payload {
            return data
        }
        return nil
    }

    public var runs: [DataRun]? {
        if case .nonResident(_, _, _, _, _, let runs) = payload {
            return runs
        }
        return nil
    }

    public var realDataSize: UInt64 {
        switch payload {
        case .resident(let data):
            return UInt64(data.count)
        case .nonResident(_, _, _, let realSize, _, _):
            return realSize
        }
    }

    public init(data: Data, offset: Int) throws {
        guard offset + 16 <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: 16, available: data.count)
        }

        var reader = BinaryReader(data: data, offset: offset)
        let rawType = try reader.readUInt32()
        self.type = AttributeType(rawValue: rawType)

        if rawType == 0xFFFFFFFF {
            // End marker
            self.recordLength = 0
            self.isNonResident = false
            self.name = nil
            self.flags = []
            self.attributeID = 0
            self.payload = .resident(Data())
            return
        }

        self.recordLength = try reader.readUInt32()
        guard self.recordLength >= 16 && offset + Int(self.recordLength) <= data.count else {
            throw NTFSError.outOfBounds(offset: UInt64(offset), requested: Int(self.recordLength), available: data.count)
        }

        self.isNonResident = (try reader.readUInt8()) != 0
        let nameLength = Int(try reader.readUInt8())
        let nameOffset = Int(try reader.readUInt16())
        self.flags = AttributeHeaderFlags(rawValue: try reader.readUInt16())
        self.attributeID = try reader.readUInt16()

        // Read optional attribute name (UTF-16LE)
        if nameLength > 0 {
            let nameStart = offset + nameOffset
            var nameReader = BinaryReader(data: data, offset: nameStart)
            self.name = try nameReader.readUTF16LEString(characterCount: nameLength)
        } else {
            self.name = nil
        }

        if !self.isNonResident {
            // Resident attribute
            let valueLength = Int(try reader.readUInt32())
            let valueOffset = Int(try reader.readUInt16())
            let _ = try reader.readUInt8() // indexed flag
            let _ = try reader.readUInt8() // padding

            let valueStart = offset + valueOffset
            guard valueStart + valueLength <= offset + Int(self.recordLength) else {
                throw NTFSError.outOfBounds(offset: UInt64(valueStart), requested: valueLength, available: data.count)
            }
            let resData = data.subdata(in: valueStart..<(valueStart + valueLength))
            self.payload = .resident(resData)
        } else {
            // Non-resident attribute
            let startingVCN = try reader.readUInt64()
            let endingVCN = try reader.readUInt64()
            let runlistOffset = Int(try reader.readUInt16())
            let _ = try reader.readUInt16() // compression unit size
            let _ = try reader.readUInt32() // padding
            let allocatedSize = try reader.readUInt64()
            let realSize = try reader.readUInt64()
            let initializedSize = try reader.readUInt64()

            let runlistStart = offset + runlistOffset
            let runlistLength = offset + Int(self.recordLength) - runlistStart
            guard runlistLength >= 0 else {
                throw NTFSError.corruptRunlist("Invalid runlist offset in non-resident attribute")
            }
            let runlistBytes = data.subdata(in: runlistStart..<(runlistStart + runlistLength))
            let runs = try RunlistDecoder.decode(data: runlistBytes)

            self.payload = .nonResident(
                startingVCN: startingVCN,
                endingVCN: endingVCN,
                allocatedSize: allocatedSize,
                realSize: realSize,
                initializedSize: initializedSize,
                runs: runs
            )
        }
    }
}
