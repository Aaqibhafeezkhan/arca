struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ArchiveError.corrupted("truncated record") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw ArchiveError.corrupted("truncated record") }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw ArchiveError.corrupted("truncated record") }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * i) }
        offset += 4
        return value
    }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw ArchiveError.corrupted("truncated record") }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
        offset += 8
        return value
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw ArchiveError.corrupted("truncated record") }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, remaining >= count else { throw ArchiveError.corrupted("truncated record") }
        offset += count
    }
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xff)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
}

extension Array where Element == UInt8 {
    func le32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func le16(at i: Int) -> UInt16 {
        UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }
}

/// Constant-time comparison for MACs.
func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}
