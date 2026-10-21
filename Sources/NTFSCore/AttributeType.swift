import Foundation

public struct AttributeType: RawRepresentable, Equatable, Hashable, CustomStringConvertible, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let standardInformation = AttributeType(rawValue: 0x10)
    public static let attributeList       = AttributeType(rawValue: 0x20)
    public static let fileName            = AttributeType(rawValue: 0x30)
    public static let objectID            = AttributeType(rawValue: 0x40)
    public static let securityDescriptor  = AttributeType(rawValue: 0x50)
    public static let volumeName          = AttributeType(rawValue: 0x60)
    public static let volumeInformation   = AttributeType(rawValue: 0x70)
    public static let data                = AttributeType(rawValue: 0x80)
    public static let indexRoot           = AttributeType(rawValue: 0x90)
    public static let indexAllocation     = AttributeType(rawValue: 0xA0)
    public static let bitmap              = AttributeType(rawValue: 0xB0)
    public static let reparsePoint        = AttributeType(rawValue: 0xC0)
    public static let eaInformation       = AttributeType(rawValue: 0xD0)
    public static let ea                  = AttributeType(rawValue: 0xE0)
    public static let loggedUtilityStream = AttributeType(rawValue: 0x100)
    public static let endMarker           = AttributeType(rawValue: 0xFFFFFFFF)

    public var description: String {
        switch self {
        case .standardInformation: return "$STANDARD_INFORMATION (0x10)"
        case .attributeList: return "$ATTRIBUTE_LIST (0x20)"
        case .fileName: return "$FILE_NAME (0x30)"
        case .objectID: return "$OBJECT_ID (0x40)"
        case .securityDescriptor: return "$SECURITY_DESCRIPTOR (0x50)"
        case .volumeName: return "$VOLUME_NAME (0x60)"
        case .volumeInformation: return "$VOLUME_INFORMATION (0x70)"
        case .data: return "$DATA (0x80)"
        case .indexRoot: return "$INDEX_ROOT (0x90)"
        case .indexAllocation: return "$INDEX_ALLOCATION (0xA0)"
        case .bitmap: return "$BITMAP (0xB0)"
        case .reparsePoint: return "$REPARSE_POINT (0xC0)"
        case .eaInformation: return "$EA_INFORMATION (0xD0)"
        case .ea: return "$EA (0xE0)"
        case .loggedUtilityStream: return "$LOGGED_UTILITY_STREAM (0x100)"
        case .endMarker: return "EndMarker (0xFFFFFFFF)"
        default: return "UnknownAttribute(0x\(String(rawValue, radix: 16)))"
        }
    }
}
