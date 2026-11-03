import Foundation

/// Writing, formatting and repairing are experimental and locked by default.
/// They are known to produce NTFS structures that Windows may reject. See docs/SAFETY.md.
/// Unlock only on throw-away images or disks: `MACNTFS_EXPERIMENTAL_UNSAFE=1`.
public enum ExperimentalGate {
    public static let environmentKey = "MACNTFS_EXPERIMENTAL_UNSAFE"

    public static var isUnlocked: Bool {
        guard let value = getenv(environmentKey) else { return false }
        return String(cString: value) == "1"
    }

    public static func require(_ feature: String) throws {
        guard isUnlocked else { throw NTFSError.experimentalDisabled(feature) }
    }
}
