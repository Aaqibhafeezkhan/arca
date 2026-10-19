import Foundation

enum ZipSignature {
    static let localFile: UInt32 = 0x0403_4b50
    static let centralFile: UInt32 = 0x0201_4b50
    static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4b50
    static let zip64Locator: UInt32 = 0x0706_4b50
    static let dataDescriptor: UInt32 = 0x0807_4b50
}

enum ZipExtraID {
    static let zip64: UInt16 = 0x0001
    static let extendedTimestamp: UInt16 = 0x5455
    static let unicodePath: UInt16 = 0x7075
    static let winZipAES: UInt16 = 0x9901
}

enum ZipMethod {
    static let store: UInt16 = 0
    static let deflate: UInt16 = 8
    static let deflate64: UInt16 = 9
    static let bzip2: UInt16 = 12
    static let lzma: UInt16 = 14
    static let zstd: UInt16 = 93
    static let xz: UInt16 = 95
    static let aes: UInt16 = 99

    static func name(_ method: UInt16) -> String {
        switch method {
        case store: "Stored"
        case 1: "Shrunk"
        case 6: "Imploded"
        case deflate: "Deflate"
        case deflate64: "Deflate64"
        case bzip2: "BZip2"
        case lzma: "LZMA"
        case zstd: "Zstandard"
        case xz: "XZ"
        case 98: "PPMd"
        default: "Method \(method)"
        }
    }
}

enum ZipFlag {
    static let encrypted: UInt16 = 1 << 0
    static let dataDescriptor: UInt16 = 1 << 3
    static let strongEncryption: UInt16 = 1 << 6
    static let utf8: UInt16 = 1 << 11
}

let zip32Max: UInt64 = 0xFFFF_FFFF

struct ZipExtraField: Equatable {
    var id: UInt16
    var data: [UInt8]

    static func parse(_ bytes: [UInt8]) -> [ZipExtraField] {
        var fields: [ZipExtraField] = []
        var r = ByteReader(bytes)
        while r.remaining >= 4 {
            guard let id = try? r.u16(), let size = try? r.u16(), let data = try? r.take(Int(size)) else { break }
            fields.append(ZipExtraField(id: id, data: data))
        }
        return fields
    }
}

extension Array where Element == ZipExtraField {
    func serialized() -> [UInt8] {
        var w = ByteWriter()
        for f in self {
            w.u16(f.id)
            w.u16(UInt16(f.data.count))
            w.append(f.data)
        }
        return w.bytes
    }

    func first(_ id: UInt16) -> ZipExtraField? { first { $0.id == id } }

    func removing(_ ids: Set<UInt16>) -> [ZipExtraField] { filter { !ids.contains($0.id) } }
}

enum ZipEncryption: Equatable {
    case none
    case zipCrypto
    case aes(strength: AESStrength, vendorVersion: UInt16, actualMethod: UInt16)
    case unsupported
}

/// One central-directory record. Values are kept verbatim so untouched
/// entries are re-emitted byte-for-byte (except offsets, which we own).
struct ZipRecord {
    var versionMadeBy: UInt16
    var versionNeeded: UInt16
    var flags: UInt16
    var method: UInt16
    var dosTime: UInt16
    var dosDate: UInt16
    var crc32: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var diskStart: UInt32
    var internalAttributes: UInt16
    var externalAttributes: UInt32
    /// Offset as stored in the archive (logical; physical = logical + prefix delta).
    var localHeaderOffset: UInt64
    var nameBytes: [UInt8]
    /// Extra fields without ZIP64, which is regenerated on write.
    var extraFields: [ZipExtraField]
    var comment: [UInt8]

    var path: String = ""
    var isDirectoryName: Bool { nameBytes.last == UInt8(ascii: "/") || nameBytes.last == UInt8(ascii: "\\") }

    var encryption: ZipEncryption {
        if flags & ZipFlag.strongEncryption != 0 { return .unsupported }
        if method == ZipMethod.aes, let f = extraFields.first(ZipExtraID.winZipAES), f.data.count >= 7,
           let strength = AESStrength(rawValue: f.data[4]) {
            return .aes(strength: strength, vendorVersion: f.data.le16(at: 0), actualMethod: f.data.le16(at: 5))
        }
        if method == ZipMethod.aes { return .unsupported }
        return flags & ZipFlag.encrypted != 0 ? .zipCrypto : .none
    }

    var effectiveMethod: UInt16 {
        if case let .aes(_, _, actual) = encryption { return actual }
        return method
    }

    var hostSystem: UInt8 { UInt8(versionMadeBy >> 8) }

    var unixMode: UInt16? {
        // 3 = Unix, 19 = OS X. Some Windows tools still set mode bits; accept non-zero.
        let mode = UInt16(truncatingIfNeeded: externalAttributes >> 16)
        if hostSystem == 3 || hostSystem == 19 || mode != 0 { return mode == 0 ? nil : mode }
        return nil
    }

    var isSymlink: Bool {
        guard let mode = unixMode else { return false }
        return mode & 0o170000 == 0o120000
    }

    var isDirectory: Bool {
        if isDirectoryName { return true }
        if let mode = unixMode, mode & 0o170000 == 0o040000 { return true }
        return externalAttributes & 0x10 != 0 && uncompressedSize == 0
    }

    var modificationDate: Date {
        if let f = extraFields.first(ZipExtraID.extendedTimestamp), f.data.count >= 5, f.data[0] & 1 != 0 {
            return Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: f.data.le32(at: 1))))
        }
        return DOSDateTime.date(time: dosTime, date: dosDate)
    }

    func decodedPath() -> String {
        let raw: String
        if flags & ZipFlag.utf8 != 0 {
            raw = String(decoding: nameBytes, as: UTF8.self)
        } else if let f = extraFields.first(ZipExtraID.unicodePath), f.data.count > 5, f.data[0] == 1,
                  f.data.le32(at: 1) == CRC32.checksum(nameBytes),
                  let s = String(bytes: f.data[5...], encoding: .utf8) {
            raw = s
        } else if let s = String(validatingUTF8CString: nameBytes) {
            // macOS Archive Utility writes UTF-8 without setting the flag.
            raw = s
        } else {
            raw = CP437.decode(nameBytes)
        }
        return ArchivePath.display(raw)
    }

    func entry() -> ArchiveEntry {
        let enc = encryption
        var methodName = ZipMethod.name(effectiveMethod)
        if case let .aes(strength, _, _) = enc { methodName += " · AES-\(strength.keyLength * 8)" }
        if enc == .zipCrypto { methodName += " · ZipCrypto" }
        return ArchiveEntry(
            path: path,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            modificationDate: modificationDate,
            posixPermissions: unixMode.map { $0 & 0o7777 },
            isEncrypted: enc != .none,
            method: isDirectory ? nil : methodName,
            crc32: (isDirectory || crc32 == 0 && uncompressedSize > 0) ? nil : crc32,
            linkTarget: nil,
            comment: comment.isEmpty ? nil : String(decoding: comment, as: UTF8.self)
        )
    }
}

private extension String {
    init?(validatingUTF8CString bytes: [UInt8]) {
        guard let s = String(bytes: bytes, encoding: .utf8) else { return nil }
        self = s
    }
}

enum DOSDateTime {
    static func date(time: UInt16, date: UInt16) -> Date {
        var c = DateComponents()
        c.year = Int((date >> 9) & 0x7f) + 1980
        c.month = max(1, Int((date >> 5) & 0x0f))
        c.day = max(1, Int(date & 0x1f))
        c.hour = Int((time >> 11) & 0x1f)
        c.minute = Int((time >> 5) & 0x3f)
        c.second = Int(time & 0x1f) * 2
        return Calendar(identifier: .gregorian).date(from: c) ?? Date(timeIntervalSince1970: 315_532_800)
    }

    static func components(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let d = UInt16(year) << 9 | UInt16(c.month ?? 1) << 5 | UInt16(c.day ?? 1)
        let t = UInt16(c.hour ?? 0) << 11 | UInt16(c.minute ?? 0) << 5 | UInt16((c.second ?? 0) / 2)
        return (t, d)
    }
}

enum CP437 {
    private static let high: [UInt16] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
    ]

    static func decode(_ bytes: [UInt8]) -> String {
        var s = String.UnicodeScalarView()
        for b in bytes {
            let scalar = b < 0x80 ? UnicodeScalar(b) : UnicodeScalar(high[Int(b) - 0x80])!
            s.append(scalar)
        }
        return String(s)
    }
}

/// Extensions whose content is already compressed; deflating them wastes time.
enum IncompressibleTypes {
    static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "mp3", "m4a", "aac", "ogg", "opus", "flac",
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "lz4",
        "dmg", "jar", "apk", "ipa", "docx", "xlsx", "pptx", "epub", "woff", "woff2", "pdf",
    ]

    static func contains(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
}
