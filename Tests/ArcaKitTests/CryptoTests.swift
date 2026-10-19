import Testing
@testable import ArcaKit

@Suite struct CryptoTests {
    @Test func aes128FIPS197() throws {
        let aes = try AESBlockEncryptor(key: bytes(fromHex: "000102030405060708090a0b0c0d0e0f"))
        var block = bytes(fromHex: "00112233445566778899aabbccddeeff")
        block.withUnsafeMutableBytes { aes.encryptBlocks($0) }
        #expect(hex(block) == "69c4e0d86a7b0430d8cdb78070b4c55a")
    }

    @Test func aes256FIPS197() throws {
        let aes = try AESBlockEncryptor(key: bytes(fromHex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        var block = bytes(fromHex: "00112233445566778899aabbccddeeff")
        block.withUnsafeMutableBytes { aes.encryptBlocks($0) }
        #expect(hex(block) == "8ea2b7ca516745bfeafc49904b496089")
    }

    @Test func hmacSHA1RFC2202() {
        let mac = HMACSHA1.mac(key: [UInt8](repeating: 0x0b, count: 20), message: Array("Hi There".utf8))
        #expect(hex(mac) == "b617318655057264e28bc0b6fb378c8ef146be00")
        let long = HMACSHA1.mac(key: [UInt8](repeating: 0xaa, count: 80),
                                message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))
        #expect(hex(long) == "aa4ae5e15272d00e95705637ce8a3b55ed402112")
    }

    @Test func pbkdf2RFC6070() {
        let pw = Array("password".utf8), salt = Array("salt".utf8)
        #expect(hex(pbkdf2SHA1(password: pw, salt: salt, iterations: 1, keyLength: 20)) == "0c60c80f961f0e71f3a9b524af6012062fe037a6")
        #expect(hex(pbkdf2SHA1(password: pw, salt: salt, iterations: 4096, keyLength: 20)) == "4b007901b765489abead49d926f721d065a429c1")
        #expect(hex(pbkdf2SHA1(password: Array("passwordPASSWORDpassword".utf8),
                               salt: Array("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8),
                               iterations: 4096, keyLength: 25)) == "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038")
    }

    @Test func crc32() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func cp437() {
        #expect(CP437.decode([0x63, 0x8A, 0x81]) == "cèü")
    }
}
