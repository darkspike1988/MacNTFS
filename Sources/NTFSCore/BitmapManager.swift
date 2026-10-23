import Foundation

/// Manages an NTFS bitmap stream ($Bitmap for cluster allocation or $MFT:$BITMAP for MFT record allocation).
public struct BitmapManager: Sendable {
    public private(set) var data: Data
    /// Byte range changed since this manager was created, so writers can stage only those bytes.
    public private(set) var dirtyBytes: Range<Int>?

    public var totalBits: Int {
        data.count * 8
    }

    public init(data: Data) {
        self.data = data
    }

    /// Checks if a given bit index is allocated (1) or free (0).
    public func isAllocated(at index: Int) -> Bool {
        guard index >= 0 && index < totalBits else { return true }
        let byteIndex = data.startIndex + (index / 8)
        let bitOffset = index % 8
        return (data[byteIndex] & (1 << bitOffset)) != 0
    }

    /// Sets the state of a bit (1 = allocated, 0 = free).
    public mutating func setAllocated(at index: Int, isAllocated: Bool) throws {
        guard index >= 0 && index < totalBits else {
            throw NTFSError.outOfBounds(offset: UInt64(index / 8), requested: 1, available: data.count)
        }
        let byteIndex = data.startIndex + (index / 8)
        let bitOffset = index % 8

        let before = data[byteIndex]
        if isAllocated {
            data[byteIndex] |= (1 << bitOffset)
        } else {
            data[byteIndex] &= ~(1 << bitOffset)
        }
        if data[byteIndex] != before {
            let changed = index / 8
            if let range = dirtyBytes {
                dirtyBytes = min(range.lowerBound, changed)..<max(range.upperBound, changed + 1)
            } else {
                dirtyBytes = changed..<(changed + 1)
            }
        }
    }

    /// Finds the first contiguous sequence of `count` free (0) bits starting search at `startIndex`.
    /// Returns the starting bit index or nil if no contiguous range is available.
    public func findContiguousFreeBits(count: Int, startIndex: Int = 0) -> Int? {
        guard count > 0 && startIndex < totalBits else { return nil }

        var consecutive = 0
        var foundStart = -1

        for i in startIndex..<totalBits {
            if !isAllocated(at: i) {
                if consecutive == 0 {
                    foundStart = i
                }
                consecutive += 1
                if consecutive == count {
                    return foundStart
                }
            } else {
                consecutive = 0
                foundStart = -1
            }
        }

        return nil
    }

    /// Allocates `count` contiguous bits and returns the starting index.
    public mutating func allocateContiguous(count: Int, startIndex: Int = 0) throws -> Int {
        guard let start = findContiguousFreeBits(count: count, startIndex: startIndex) else {
            throw NTFSError.unsupportedFeature("Disk is full: cannot find \(count) contiguous free blocks")
        }

        for i in start..<(start + count) {
            try setAllocated(at: i, isAllocated: true)
        }

        return start
    }

    /// Frees `count` contiguous bits starting at `startIndex`.
    public mutating func freeContiguous(startIndex: Int, count: Int) throws {
        for i in startIndex..<(startIndex + count) {
            try setAllocated(at: i, isAllocated: false)
        }
    }

    /// First free bit at or after `start`, skipping fully allocated bytes.
    func firstFree(from start: Int, below end: Int) -> Int? {
        var i = start
        while i < end {
            if i % 8 == 0, i + 8 <= end, data[data.startIndex + i / 8] == 0xFF { i += 8; continue }
            if !isAllocated(at: i) { return i }
            i += 1
        }
        return nil
    }

    /// Start of the first run of `length` free bits within `start..<end`.
    func firstFreeRun(length: Int, from start: Int, below end: Int) -> Int? {
        var i = start
        while let free = firstFree(from: i, below: end) {
            var j = free
            while j < end && j - free < length && !isAllocated(at: j) { j += 1 }
            if j - free == length { return free }
            i = j
        }
        return nil
    }
}
