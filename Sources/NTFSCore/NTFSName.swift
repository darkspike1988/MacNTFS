import Foundation

/// NTFS compares file names by UTF-16 code units. It does not normalize Unicode,
/// so "é" as one character and "e" plus a combining accent are two different names.
enum NTFSName {
    static func isExactMatch(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    /// Case-insensitive match by simple per-character upper-casing.
    /// An approximation of the volume's `$UpCase` table, which maps one UTF-16 unit to one UTF-16 unit.
    static func isCaseInsensitiveMatch(_ a: String, _ b: String) -> Bool {
        folded(a).elementsEqual(folded(b))
    }

    private static func folded(_ name: String) -> [UInt16] {
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
