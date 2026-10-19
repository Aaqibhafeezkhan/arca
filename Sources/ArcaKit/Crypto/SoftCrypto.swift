#if !canImport(CommonCrypto)
// Portable fallbacks used only where CommonCrypto is unavailable (Linux CI).
// Apple builds go through CommonCrypto exclusively.

struct SHA1 {
    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0)
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        length += UInt64(data.count)
        var index = 0
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, data.count)
            buffer += data[0..<take]
            index = take
            if buffer.count == 64 {
                buffer.withUnsafeBytes { process($0.baseAddress!) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while data.count - index >= 64 {
            process(data.baseAddress!.advanced(by: index))
            index += 64
        }
        if index < data.count { buffer += data[index..<data.count] }
    }

    mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var padding: [UInt8] = [0x80]
        let padLength = (56 - (buffer.count + 1) % 64 + 64) % 64
        padding += [UInt8](repeating: 0, count: padLength)
        for i in (0..<8).reversed() { padding.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }
        let savedLength = length
        update(padding)
        length = savedLength
        var out: [UInt8] = []
        for word in [h.0, h.1, h.2, h.3, h.4] {
            out += [UInt8(word >> 24), UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0xff), UInt8(word & 0xff)]
        }
        return out
    }

    static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var s = SHA1()
        s.update(bytes)
        return s.finalize()
    }

    private mutating func process(_ block: UnsafeRawPointer) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            let b = block.advanced(by: i * 4).assumingMemoryBound(to: UInt8.self)
            w[i] = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        }
        for i in 16..<80 {
            let v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
            w[i] = v << 1 | v >> 31
        }
        var (a, b, c, d, e) = h
        for i in 0..<80 {
            let f: UInt32, k: UInt32
            switch i {
            case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
            case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
            default: f = b ^ c ^ d; k = 0xCA62C1D6
            }
            let temp = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = b << 30 | b >> 2; b = a; a = temp
        }
        h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
    }
}

/// Straightforward FIPS-197 AES encryption (no T-tables).
struct SoftAES {
    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    private let roundKeys: [UInt8]
    private let rounds: Int

    init(key: [UInt8]) {
        let nk = key.count / 4
        rounds = nk + 6
        var w = key
        var rcon: UInt8 = 1
        var i = nk
        while i < 4 * (rounds + 1) {
            var t = Array(w[(i - 1) * 4..<i * 4])
            if i % nk == 0 {
                t = [Self.sbox[Int(t[1])] ^ rcon, Self.sbox[Int(t[2])], Self.sbox[Int(t[3])], Self.sbox[Int(t[0])]]
                rcon = Self.xtime(rcon)
            } else if nk > 6, i % nk == 4 {
                t = t.map { Self.sbox[Int($0)] }
            }
            for j in 0..<4 { w.append(w[(i - nk) * 4 + j] ^ t[j]) }
            i += 1
        }
        roundKeys = w
    }

    @inline(__always) private static func xtime(_ x: UInt8) -> UInt8 {
        (x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0)
    }

    func encryptBlock(_ s: UnsafeMutablePointer<UInt8>) {
        for i in 0..<16 { s[i] ^= roundKeys[i] }
        for round in 1...rounds {
            for i in 0..<16 { s[i] = Self.sbox[Int(s[i])] }
            // ShiftRows (column-major state).
            var t = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t
            t = s[2]; s[2] = s[10]; s[10] = t; t = s[6]; s[6] = s[14]; s[14] = t
            t = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t
            if round != rounds {
                for c in 0..<4 {
                    let a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3]
                    let all = a0 ^ a1 ^ a2 ^ a3
                    s[c * 4] = a0 ^ all ^ Self.xtime(a0 ^ a1)
                    s[c * 4 + 1] = a1 ^ all ^ Self.xtime(a1 ^ a2)
                    s[c * 4 + 2] = a2 ^ all ^ Self.xtime(a2 ^ a3)
                    s[c * 4 + 3] = a3 ^ all ^ Self.xtime(a3 ^ a0)
                }
            }
            for i in 0..<16 { s[i] ^= roundKeys[round * 16 + i] }
        }
    }
}
#endif
