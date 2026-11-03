import Foundation

/// The `$UpCase` table of a volume: for every UTF-16 code unit the unit that NTFS compares it as.
/// NTFS file name lookup ignores case by mapping both names through this table.
struct UpCaseTable: Sendable {
    /// 65536 entries of 2 bytes.
    static let byteCount = 65_536 * 2

    private let table: [UInt16]

    init?(data: Data) {
        guard data.count == UpCaseTable.byteCount else { return nil }
        // One bulk copy. The table is stored little-endian.
        var entries = [UInt16](repeating: 0, count: 65_536)
        entries.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
        if UInt16(littleEndian: 1) != 1 {
            entries = entries.map { UInt16(littleEndian: $0) }
        }
        table = entries
    }

    func fold(_ unit: UInt16) -> UInt16 {
        table[Int(unit)]
    }

    func fold(_ units: [UInt16]) -> [UInt16] {
        units.map { table[Int($0)] }
    }
}

/// NTFS compares file names by UTF-16 code units. It does not normalize Unicode,
/// so "é" as one character and "e" plus a combining accent are two different names.
enum NTFSName {
    static func isExactMatch(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    /// Case-insensitive match. Uses the volume's `$UpCase` table; without one it upper-cases every
    /// character on its own, which agrees with the usual table for most names.
    static func isCaseInsensitiveMatch(_ a: String, _ b: String, upCase: UpCaseTable? = nil) -> Bool {
        if let upCase {
            return upCase.fold(Array(a.utf16)) == upCase.fold(Array(b.utf16))
        }
        return approximateFold(a).elementsEqual(approximateFold(b))
    }

    /// Upper-cases every character on its own. Used when the volume's table is not available.
    static func approximateFold(_ name: String) -> [UInt16] {
        var units = [UInt16]()
        units.reserveCapacity(name.utf16.count)
        for scalar in name.unicodeScalars {
            let upper = scalar.properties.uppercaseMapping.unicodeScalars
            let mapped = upper.count == 1 ? upper.first! : scalar
            units.append(contentsOf: String(Character(mapped)).utf16)
        }
        return units
    }
}
