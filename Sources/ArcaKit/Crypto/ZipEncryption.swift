/// Traditional PKWARE stream cipher ("ZipCrypto"). Read support only: it is
/// broken and new archives are always written with AES.
struct ZipCryptoKeys {
    private var k0: UInt32 = 0x1234_5678
    private var k1: UInt32 = 0x2345_6789
    private var k2: UInt32 = 0x3456_7890

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    init(password: [UInt8]) {
        for b in password { update(b) }
    }

    @inline(__always) private static func crc(_ crc: UInt32, _ b: UInt8) -> UInt32 {
        table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8)
    }

    @inline(__always) private mutating func update(_ b: UInt8) {
        k0 = Self.crc(k0, b)
        k1 = (k1 &+ (k0 & 0xff)) &* 134_775_813 &+ 1
        k2 = Self.crc(k2, UInt8(k1 >> 24))
    }

    @inline(__always) private func streamByte() -> UInt8 {
        let t = (k2 | 2) & 0xffff
        return UInt8(truncatingIfNeeded: (t &* (t ^ 1)) >> 8)
    }

    @inline(__always) mutating func decrypt(_ c: UInt8) -> UInt8 {
        let p = c ^ streamByte()
        update(p)
        return p
    }
}

final class ZipCryptoDecryptSink: DataSink {
    private var keys: ZipCryptoKeys
    private let next: DataSink
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

    /// `keys` must already have consumed the 12-byte encryption header.
    init(keys: ZipCryptoKeys, next: DataSink) {
        self.keys = keys
        self.next = next
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < chunk.count {
            let n = min(scratch.count, chunk.count - offset)
            for i in 0..<n { scratch[i] = keys.decrypt(chunk[offset + i]) }
            try scratch.withUnsafeBytes { try next.write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            offset += n
        }
    }

    func finish() throws { try next.finish() }
}

// MARK: - WinZip AES (AE-1 / AE-2)

enum AESStrength: UInt8, Sendable {
    case aes128 = 1, aes192 = 2, aes256 = 3

    var keyLength: Int { [16, 24, 32][Int(rawValue) - 1] }
    var saltLength: Int { [8, 12, 16][Int(rawValue) - 1] }
}

struct WinZipAESKeys {
    static let iterations = 1000
    static let macLength = 10

    let encryptionKey: [UInt8]
    let macKey: [UInt8]
    let verifier: [UInt8]

    init(password: [UInt8], salt: [UInt8], strength: AESStrength) {
        let n = strength.keyLength
        let derived = pbkdf2SHA1(password: password, salt: salt, iterations: Self.iterations, keyLength: 2 * n + 2)
        encryptionKey = Array(derived[0..<n])
        macKey = Array(derived[n..<2 * n])
        verifier = Array(derived[2 * n..<2 * n + 2])
    }
}

/// AES-CTR with WinZip's little-endian counter starting at 1.
final class WinZipCTR {
    private let aes: AESBlockEncryptor
    private var counter: UInt64 = 1
    private var keystream = [UInt8](repeating: 0, count: 64 * 1024)
    private var available = 0
    private var position = 0

    init(key: [UInt8]) throws { aes = try AESBlockEncryptor(key: key) }

    private func refill() {
        let blocks = keystream.count / 16
        keystream.withUnsafeMutableBytes { buf in
            for b in 0..<blocks {
                let base = b * 16
                var c = counter
                for i in 0..<16 {
                    buf[base + i] = i < 8 ? UInt8(truncatingIfNeeded: c) : 0
                    if i < 8 { c >>= 8 }
                }
                counter &+= 1
            }
            aes.encryptBlocks(buf)
        }
        available = keystream.count
        position = 0
    }

    func apply(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) {
        for i in 0..<input.count {
            if position == available { refill() }
            output[i] = input[i] ^ keystream[position]
            position += 1
        }
    }
}

final class AESDecryptSink: DataSink {
    private let ctr: WinZipCTR
    private var hmac: HMACSHA1
    private let next: DataSink
    private let expectedMAC: [UInt8]
    private let entry: String
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

    init(keys: WinZipAESKeys, expectedMAC: [UInt8], entry: String, next: DataSink) throws {
        ctr = try WinZipCTR(key: keys.encryptionKey)
        hmac = HMACSHA1(key: keys.macKey)
        self.expectedMAC = expectedMAC
        self.entry = entry
        self.next = next
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        hmac.update(chunk)
        var offset = 0
        while offset < chunk.count {
            let n = min(scratch.count, chunk.count - offset)
            scratch.withUnsafeMutableBytes { out in
                ctr.apply(UnsafeRawBufferPointer(rebasing: chunk[offset..<offset + n]),
                          into: UnsafeMutableRawBufferPointer(rebasing: out[0..<n]))
            }
            try scratch.withUnsafeBytes { try next.write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            offset += n
        }
    }

    func finish() throws {
        let mac = Array(hmac.finalize().prefix(WinZipAESKeys.macLength))
        guard constantTimeEqual(mac, expectedMAC) else { throw ArchiveError.checksumMismatch(entry: entry) }
        try next.finish()
    }
}

/// Emits salt + verifier first, ciphertext, then the 10-byte authentication code.
final class AESEncryptSink: DataSink {
    private let ctr: WinZipCTR
    private var hmac: HMACSHA1
    private let next: DataSink
    private var header: [UInt8]?
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

    static func overhead(_ strength: AESStrength) -> UInt64 {
        UInt64(strength.saltLength + 2 + WinZipAESKeys.macLength)
    }

    init(password: [UInt8], strength: AESStrength, next: DataSink) throws {
        let salt = secureRandomBytes(strength.saltLength)
        let keys = WinZipAESKeys(password: password, salt: salt, strength: strength)
        ctr = try WinZipCTR(key: keys.encryptionKey)
        hmac = HMACSHA1(key: keys.macKey)
        header = salt + keys.verifier
        self.next = next
    }

    private func emitHeader() throws {
        if let header {
            try next.write(header)
            self.header = nil
        }
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        try emitHeader()
        var offset = 0
        while offset < chunk.count {
            let n = min(scratch.count, chunk.count - offset)
            scratch.withUnsafeMutableBytes { out in
                ctr.apply(UnsafeRawBufferPointer(rebasing: chunk[offset..<offset + n]),
                          into: UnsafeMutableRawBufferPointer(rebasing: out[0..<n]))
            }
            try scratch.withUnsafeBytes {
                let slice = UnsafeRawBufferPointer(rebasing: $0[0..<n])
                hmac.update(slice)
                try next.write(slice)
            }
            offset += n
        }
    }

    func finish() throws {
        try emitHeader()
        try next.write(Array(hmac.finalize().prefix(WinZipAESKeys.macLength)))
        try next.finish()
    }
}
