import Foundation

public enum NTFSError: Error, LocalizedError, Sendable {
    case invalidBootSector(String)
    case invalidSignature(expected: String, found: String)
    case fixupVerificationFailed(sectorIndex: Int, expected: UInt16, found: UInt16)
    case outOfBounds(offset: UInt64, requested: Int, available: Int)
    case unsupportedFeature(String)
    case recordNotAllocated(recordNumber: UInt64)
    case attributeNotFound(type: UInt32, name: String?)
    case corruptRunlist(String)
    case corruptDirectoryIndex(String)
    case pathNotFound(String)
    case notADirectory(String)
    case invalidIndexEntry

    public var errorDescription: String? {
        switch self {
        case .invalidBootSector(let msg):
            return "Invalid NTFS Boot Sector: \(msg)"
        case .invalidSignature(let expected, let found):
            return "Invalid signature. Expected '\(expected)', found '\(found)'"
        case .fixupVerificationFailed(let sector, let exp, let fnd):
            return "NTFS Multi-Sector Fixup check failed on sector \(sector): expected 0x\(String(exp, radix: 16)), got 0x\(String(fnd, radix: 16))"
        case .outOfBounds(let offset, let requested, let available):
            return "Out of bounds reading \(requested) bytes at offset \(offset) (available: \(available))"
        case .unsupportedFeature(let msg):
            return "Unsupported NTFS feature: \(msg)"
        case .recordNotAllocated(let num):
            return "MFT record \(num) is not allocated or marked in-use"
        case .attributeNotFound(let type, let name):
            let nameStr = name != nil ? " with name '\(name!)'" : ""
            return "NTFS attribute 0x\(String(type, radix: 16))\(nameStr) not found"
        case .corruptRunlist(let msg):
            return "Corrupt data runlist: \(msg)"
        case .corruptDirectoryIndex(let msg):
            return "Corrupt directory index: \(msg)"
        case .pathNotFound(let path):
            return "Path not found: '\(path)'"
        case .notADirectory(let path):
            return "Not a directory: '\(path)'"
        case .invalidIndexEntry:
            return "Invalid index entry in directory B-Tree"
        }
    }
}
