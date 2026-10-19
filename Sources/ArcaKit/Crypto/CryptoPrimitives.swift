#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// AES block encryption in ECB mode — the only primitive WinZip AES-CTR needs.
final class AESBlockEncryptor {
    #if canImport(CommonCrypto)
    private var cryptor: CCCryptorRef?
    #else
    private let soft: SoftAES
    #endif

    init(key: [UInt8]) throws {
        guard [16, 24, 32].contains(key.count) else { throw ArchiveError.unsupported("AES key length \(key.count)") }
        #if canImport(CommonCrypto)
        let status = key.withUnsafeBytes {
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            $0.baseAddress, key.count, nil, &cryptor)
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw ArchiveError.unsupported("AES unavailable (\(status))") }
        #else
        soft = SoftAES(key: key)
        #endif
    }

    deinit {
        #if canImport(CommonCrypto)
        if let cryptor { CCCryptorRelease(cryptor) }
        #endif
    }

    /// Encrypts `buffer` (multiple of 16 bytes) in place.
    func encryptBlocks(_ buffer: UnsafeMutableRawBufferPointer) {
        precondition(buffer.count % 16 == 0)
        #if canImport(CommonCrypto)
        var moved = 0
        CCCryptorUpdate(cryptor, buffer.baseAddress, buffer.count, buffer.baseAddress, buffer.count, &moved)
        #else
        var offset = 0
        while offset < buffer.count {
            soft.encryptBlock(buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self))
            offset += 16
        }
        #endif
    }
}

struct HMACSHA1 {
    static let digestLength = 20

    #if canImport(CommonCrypto)
    private var context = CCHmacContext()
    #else
    private var inner: SHA1
    private var outerKey: [UInt8]
    #endif

    init(key: [UInt8]) {
        #if canImport(CommonCrypto)
        key.withUnsafeBytes { CCHmacInit(&context, CCHmacAlgorithm(kCCHmacAlgSHA1), $0.baseAddress, key.count) }
        #else
        var k = key.count > 64 ? SHA1.hash(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        inner = SHA1()
        inner.update(k.map { $0 ^ 0x36 })
        outerKey = k.map { $0 ^ 0x5c }
        #endif
    }

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        guard buffer.count > 0 else { return }
        #if canImport(CommonCrypto)
        CCHmacUpdate(&context, buffer.baseAddress, buffer.count)
        #else
        inner.update(buffer)
        #endif
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    mutating func finalize() -> [UInt8] {
        #if canImport(CommonCrypto)
        var mac = [UInt8](repeating: 0, count: Self.digestLength)
        mac.withUnsafeMutableBytes { CCHmacFinal(&context, $0.baseAddress) }
        return mac
        #else
        let innerDigest = inner.finalize()
        var outer = SHA1()
        outer.update(outerKey)
        outer.update(innerDigest)
        return outer.finalize()
        #endif
    }

    static func mac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var h = HMACSHA1(key: key)
        h.update(message)
        return h.finalize()
    }
}

func pbkdf2SHA1(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> [UInt8] {
    #if canImport(CommonCrypto)
    var derived = [UInt8](repeating: 0, count: keyLength)
    let status = password.withUnsafeBytes { pw in
        derived.withUnsafeMutableBytes { out in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                 salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(iterations),
                                 out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
        }
    }
    precondition(status == Int32(kCCSuccess), "PBKDF2 failed")
    return derived
    #else
    var derived: [UInt8] = []
    var block: UInt32 = 1
    while derived.count < keyLength {
        var u = HMACSHA1.mac(key: password, message: salt + [UInt8(block >> 24), UInt8((block >> 16) & 0xff),
                                                              UInt8((block >> 8) & 0xff), UInt8(block & 0xff)])
        var t = u
        if iterations > 1 {
            for _ in 1..<iterations {
                u = HMACSHA1.mac(key: password, message: u)
                for i in 0..<t.count { t[i] ^= u[i] }
            }
        }
        derived += t
        block += 1
    }
    return Array(derived.prefix(keyLength))
    #endif
}

func secureRandomBytes(_ count: Int) -> [UInt8] {
    var rng = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
}
