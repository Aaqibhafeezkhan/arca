import Foundation

public enum ArchiveFormat: String, Sendable, CaseIterable, Codable {
    case zip
    case tar, tarGzip, tarBzip2, tarXz, tarZstd, tarLz4, tarLzma, tarLzip, tarCompress
    case sevenZip, rar, rar5, iso9660, cab, xar, cpio, lha, ar, warc, mtree
    case gzip, bzip2, xz, zstd, lz4
    case rpm, dmg, wim, vhd, msi, squashfs, chm, arj, udf
    case other

    public var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .tar: "TAR"
        case .tarGzip: "TAR.GZ"
        case .tarBzip2: "TAR.BZ2"
        case .tarXz: "TAR.XZ"
        case .tarZstd: "TAR.ZST"
        case .tarLz4: "TAR.LZ4"
        case .tarLzma: "TAR.LZMA"
        case .tarLzip: "TAR.LZ"
        case .tarCompress: "TAR.Z"
        case .sevenZip: "7-Zip"
        case .rar: "RAR"
        case .rar5: "RAR 5"
        case .iso9660: "ISO 9660"
        case .cab: "Cabinet"
        case .xar: "XAR"
        case .cpio: "CPIO"
        case .lha: "LHA"
        case .ar: "AR"
        case .warc: "WARC"
        case .mtree: "mtree"
        case .gzip: "GZip"
        case .bzip2: "BZip2"
        case .xz: "XZ"
        case .zstd: "Zstandard"
        case .lz4: "LZ4"
        case .rpm: "RPM"
        case .dmg: "Disk Image"
        case .wim: "WIM"
        case .vhd: "Virtual Disk"
        case .msi: "Windows Installer"
        case .squashfs: "SquashFS"
        case .chm: "CHM"
        case .arj: "ARJ"
        case .udf: "UDF"
        case .other: "Archive"
        }
    }

    public var preferredExtension: String {
        switch self {
        case .zip: "zip"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXz: "tar.xz"
        case .tarZstd: "tar.zst"
        case .tarLz4: "tar.lz4"
        case .tarLzma: "tar.lzma"
        case .tarLzip: "tar.lz"
        case .tarCompress: "tar.Z"
        case .sevenZip: "7z"
        case .rar, .rar5: "rar"
        case .iso9660: "iso"
        case .cab: "cab"
        case .xar: "xar"
        case .cpio: "cpio"
        case .lha: "lzh"
        case .ar: "a"
        case .warc: "warc"
        case .mtree: "mtree"
        case .gzip: "gz"
        case .bzip2: "bz2"
        case .xz: "xz"
        case .zstd: "zst"
        case .lz4: "lz4"
        case .rpm: "rpm"
        case .dmg: "dmg"
        case .wim: "wim"
        case .vhd: "vhdx"
        case .msi: "msi"
        case .squashfs: "squashfs"
        case .chm: "chm"
        case .arj: "arj"
        case .udf: "udf"
        case .other: "bin"
        }
    }

    /// Formats the app can create from scratch. 7z needs 7-Zip and RAR the
    /// RARLAB `rar` tool (see `ExternalTools`).
    public static var creatable: [ArchiveFormat] {
        var formats: [ArchiveFormat] = [.zip]
        if ExternalTools.sevenZip != nil { formats.append(.sevenZip) }
        formats += [.tarGzip, .tarXz, .tarZstd, .tarBzip2, .tar]
        if ExternalTools.rar != nil { formats.append(.rar) }
        return formats
    }

    /// Formats whose writer can encrypt (AES-256).
    public var supportsEncryption: Bool {
        switch self {
        case .zip, .sevenZip, .rar, .rar5: true
        default: false
        }
    }

    /// Formats handled by 7-Zip rather than libarchive.
    var prefersSevenZip: Bool {
        switch self {
        case .sevenZip, .rar, .rar5, .wim, .vhd, .msi, .squashfs, .chm, .arj, .udf: true
        default: false
        }
    }

    /// Human label for container files that are archives in disguise.
    public static func documentKind(forFilename name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return [
            "cbz": "Comic Book (ZIP)", "cbr": "Comic Book (RAR)", "cb7": "Comic Book (7-Zip)", "cbt": "Comic Book (TAR)",
            "jar": "Java Archive", "apk": "Android Package", "aab": "Android App Bundle", "ipa": "iOS App",
            "appx": "Windows App Package", "msix": "Windows App Package", "epub": "EPUB Book",
            "docx": "Word Document", "xlsx": "Excel Workbook", "pptx": "PowerPoint Presentation",
            "odt": "OpenDocument Text", "ods": "OpenDocument Spreadsheet", "deb": "Debian Package",
            "pkg": "Installer Package", "xip": "Signed Xcode Archive", "vsix": "VS Code Extension",
        ][ext]
    }

    public var isTarFamily: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tarLz4, .tarLzma, .tarLzip, .tarCompress: true
        default: false
        }
    }

    /// Best guess from a filename, used for new archives and as a fallback.
    public static func guess(fromFilename name: String) -> ArchiveFormat? {
        let lower = name.lowercased()
        let table: [(String, ArchiveFormat)] = [
            (".tar.gz", .tarGzip), (".tgz", .tarGzip), (".tar.bz2", .tarBzip2), (".tbz2", .tarBzip2), (".tbz", .tarBzip2),
            (".tar.xz", .tarXz), (".txz", .tarXz), (".tar.zst", .tarZstd), (".tzst", .tarZstd), (".tar.lz4", .tarLz4),
            (".tar.lzma", .tarLzma), (".tar.lz", .tarLzip), (".tar.z", .tarCompress), (".tar", .tar),
            (".zip", .zip), (".jar", .zip), (".apk", .zip), (".ipa", .zip), (".docx", .zip), (".xlsx", .zip),
            (".pptx", .zip), (".odt", .zip), (".ods", .zip), (".epub", .zip), (".cbz", .zip), (".aab", .zip),
            (".appx", .zip), (".msix", .zip), (".appxbundle", .zip), (".msixbundle", .zip), (".vsix", .zip),
            (".7z", .sevenZip), (".cb7", .sevenZip), (".rar", .rar), (".cbr", .rar), (".cbt", .tar),
            (".iso", .iso9660), (".cab", .cab), (".xar", .xar), (".pkg", .xar), (".xip", .xar), (".cpio", .cpio),
            (".lzh", .lha), (".lha", .lha), (".deb", .ar), (".rpm", .rpm), (".dmg", .dmg), (".wim", .wim),
            (".swm", .wim), (".esd", .wim), (".vhd", .vhd), (".vhdx", .vhd), (".msi", .msi), (".squashfs", .squashfs),
            (".sqsh", .squashfs), (".sfs", .squashfs), (".chm", .chm), (".arj", .arj), (".udf", .udf),
            (".gz", .gzip), (".bz2", .bzip2), (".xz", .xz), (".zst", .zstd), (".lz4", .lz4),
        ]
        return table.first { lower.hasSuffix($0.0) }?.1
    }
}

public enum EditingMode: Sendable, Equatable {
    /// Unchanged entries stay where they are; only new data is written.
    case inPlace
    /// The archive is re-streamed into a new file; `recompresses` is true when
    /// an outer compression filter has to be re-applied to the whole stream.
    case streamRewrite(recompresses: Bool)
    case readOnly

    public var isEditable: Bool { self != .readOnly }
}

public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    /// Normalised path: "/"-separated, no leading or trailing slash.
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64?
    public let modificationDate: Date?
    public let posixPermissions: UInt16?
    public let isEncrypted: Bool
    public let method: String?
    public let crc32: UInt32?
    public let linkTarget: String?
    public let hardLinkTarget: String?
    public let comment: String?

    public var id: String { path }
    public var name: String { ArchivePath.lastComponent(path) }
    public var parentPath: String { ArchivePath.parent(path) }

    public var compressionRatio: Double? {
        guard let compressedSize, uncompressedSize > 0 else { return nil }
        return 1 - Double(compressedSize) / Double(uncompressedSize)
    }

    public init(path: String, isDirectory: Bool, isSymlink: Bool = false, uncompressedSize: UInt64,
                compressedSize: UInt64? = nil, modificationDate: Date? = nil, posixPermissions: UInt16? = nil,
                isEncrypted: Bool = false, method: String? = nil, crc32: UInt32? = nil, linkTarget: String? = nil,
                hardLinkTarget: String? = nil, comment: String? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.modificationDate = modificationDate
        self.posixPermissions = posixPermissions
        self.isEncrypted = isEncrypted
        self.method = method
        self.crc32 = crc32
        self.linkTarget = linkTarget
        self.hardLinkTarget = hardLinkTarget
        self.comment = comment
    }
}

public enum ArchiveChange: Sendable, Hashable {
    /// Adds (or replaces) `source` — a file, folder (recursive) or symlink — at `path`.
    case add(source: URL, at: String)
    case addData(Data, at: String)
    case makeDirectory(String)
    /// Removes an entry; for folders, everything below it.
    case delete(String)
    /// Renames or moves an entry or folder.
    case rename(from: String, to: String)
}

public enum EncryptionMethod: Sendable, Hashable {
    case none
    case aes256(password: String)
}

public struct WriteOptions: Sendable, Hashable {
    /// 0 = store, 1...9 = deflate / filter level.
    public var compressionLevel: Int
    public var encryption: EncryptionMethod
    /// Store (don't recompress) already-compressed media such as JPEG, MP4, ZIP.
    public var storeCompressedMedia: Bool
    /// Skip `.DS_Store` and `__MACOSX` when adding folders.
    public var excludeMacMetadata: Bool

    public init(compressionLevel: Int = 6, encryption: EncryptionMethod = .none,
                storeCompressedMedia: Bool = true, excludeMacMetadata: Bool = true) {
        self.compressionLevel = compressionLevel
        self.encryption = encryption
        self.storeCompressedMedia = storeCompressedMedia
        self.excludeMacMetadata = excludeMacMetadata
    }

    public static let `default` = WriteOptions()
}

public enum ConflictPolicy: Sendable {
    case overwrite, skip, keepBoth
}

public struct ArchiveStatistics: Sendable, Equatable {
    public var fileCount: Int
    public var folderCount: Int
    public var totalUncompressed: UInt64
    public var totalCompressed: UInt64?
    public var archiveSize: UInt64
    /// Space occupied by superseded entries (ZIP in-place edits); reclaimed by compacting.
    public var reclaimableBytes: UInt64
}

public enum ArchivePath {
    /// Normalises user/archive paths; throws for traversal or absolute paths.
    public static func normalize(_ raw: String) throws -> String {
        let components = try safeComponents(raw)
        return components.joined(separator: "/")
    }

    static func safeComponents(_ raw: String) throws -> [String] {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        var components: [String] = []
        for part in unified.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { throw ArchiveError.invalidPath(raw) }
            components.append(String(part))
        }
        return components
    }

    /// Lenient normalisation for names read from archives (keeps ".." visible
    /// in the UI; extraction re-validates).
    static func display(_ raw: String) -> String {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        return unified.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
    }

    public static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    public static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        ancestor.isEmpty || path.hasPrefix(ancestor + "/")
    }

    /// `path` re-rooted from `old` to `new` if it is `old` or below it.
    static func rebase(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        if isDescendant(path, of: old) { return join(new, String(path.dropFirst(old.count + 1))) }
        return nil
    }
}
