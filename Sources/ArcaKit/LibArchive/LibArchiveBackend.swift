import Foundation
import CArchive
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum LA {
    // Format families (archive.h: ARCHIVE_FORMAT_*), defined here because the
    // C headers build them with expressions Swift doesn't import.
    static let baseMask: Int32 = 0xFF0000
    static let cpio: Int32 = 0x10000
    static let tar: Int32 = 0x30000
    static let iso9660: Int32 = 0x40000
    static let zip: Int32 = 0x50000
    static let empty: Int32 = 0x60000
    static let ar: Int32 = 0x70000
    static let mtree: Int32 = 0x80000
    static let raw: Int32 = 0x90000
    static let xar: Int32 = 0xA0000
    static let lha: Int32 = 0xB0000
    static let cab: Int32 = 0xC0000
    static let rar: Int32 = 0xD0000
    static let sevenZip: Int32 = 0xE0000
    static let warc: Int32 = 0xF0000
    static let rar5: Int32 = 0x100000
    static let paxRestricted: Int32 = tar | 3

    static let filterNone: Int32 = 0
    static let gzip: Int32 = 1
    static let bzip2: Int32 = 2
    static let compress: Int32 = 3
    static let lzma: Int32 = 5
    static let xz: Int32 = 6
    static let lzip: Int32 = 9
    static let lz4: Int32 = 13
    static let zstd: Int32 = 14
    static let rpm: Int32 = 8

    static let typeMask: UInt32 = 0o170000
    static let regular: UInt32 = 0o100000
    static let directory: UInt32 = 0o040000
    static let symlink: UInt32 = 0o120000

    static let writableFilters: Set<Int32> = [gzip, bzip2, compress, lzma, xz, lzip, lz4, zstd]
}

private func message(_ a: OpaquePointer?) -> String {
    guard let a, let cString = archive_error_string(a) else { return "Unknown libarchive error" }
    return String(cString: cString)
}

/// Read access to any libarchive format; streaming rewrite for the tar family.
final class LibArchiveBackend: ArchiveBackend {
    let path: String
    private let forceReadOnly: Bool
    private var identity: FileIdentity

    private(set) var format: ArchiveFormat = .other
    private(set) var editingMode: EditingMode = .readOnly
    private(set) var entries: [ArchiveEntry] = []
    private(set) var notes: [String] = []
    private(set) var isEncrypted = false
    var passwords: [String]

    /// One element per header in archive order (duplicates included).
    private var headers: [ArchiveEntry] = []
    private var formatCode: Int32 = 0
    private var filterCodes: [Int32] = []
    private var useRawFormat = false

    init(path: String, passwords: [String] = [], forceReadOnly: Bool = false) throws {
        self.path = path
        self.passwords = passwords
        self.forceReadOnly = forceReadOnly
        identity = try FileIdentity(path: path)
        try scan(progress: nil)
    }

    // MARK: - Reader

    private func openReader() throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw ArchiveError.libarchive("Out of memory") }
        archive_read_support_filter_all(a)
        if useRawFormat {
            archive_read_support_format_raw(a)
        } else {
            archive_read_support_format_all(a)
        }
        for p in passwords { archive_read_add_passphrase(a, p) }
        guard archive_read_open_filename(a, path, 64 * 1024) == ARCHIVE_OK else {
            let error = translate(message(a), entry: "")
            archive_read_free(a)
            throw error
        }
        return a
    }

    private func translate(_ text: String, entry: String) -> ArchiveError {
        let lower = text.lowercased()
        if lower.contains("passphrase") || lower.contains("password") || lower.contains("decryption") {
            if lower.contains("unsupported") || lower.contains("not supported") {
                return .unsupported(text)
            }
            return passwords.isEmpty ? .passwordRequired(entry: entry) : .wrongPassword(entry: entry)
        }
        if lower.contains("unrecognized archive format") { return .notAnArchive(path) }
        return .libarchive(text)
    }

    /// Returns nil at end of archive.
    private func nextHeader(_ a: OpaquePointer) throws -> OpaquePointer? {
        var entry: OpaquePointer?
        let status = archive_read_next_header(a, &entry)
        switch status {
        case ARCHIVE_OK, ARCHIVE_WARN: return entry
        case ARCHIVE_EOF: return nil
        default: throw translate(message(a), entry: "")
        }
    }

    private func makeEntry(_ e: OpaquePointer) -> ArchiveEntry {
        var rawPath = archive_entry_pathname_utf8(e).map { String(cString: $0) }
            ?? archive_entry_pathname(e).map { String(cString: $0) } ?? ""
        if useRawFormat || rawPath == "data" && formatCode & LA.baseMask == LA.raw {
            rawPath = Self.rawEntryName(for: path)
        }
        let type = UInt32(archive_entry_filetype(e))
        let isDir = type == LA.directory || rawPath.hasSuffix("/")
        let isLink = type == LA.symlink
        let size: UInt64 = archive_entry_size_is_set(e) != 0 ? UInt64(max(0, archive_entry_size(e))) : 0
        let mtime: Date? = archive_entry_mtime_is_set(e) != 0
            ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(e))) : nil
        let target = isLink ? (archive_entry_symlink_utf8(e) ?? archive_entry_symlink(e)).map { String(cString: $0) } : nil
        let hardlink = (archive_entry_hardlink_utf8(e) ?? archive_entry_hardlink(e)).map { ArchivePath.display(String(cString: $0)) }
        let perm = UInt16(truncatingIfNeeded: UInt32(archive_entry_perm(e)) & 0o7777)
        return ArchiveEntry(path: ArchivePath.display(rawPath), isDirectory: isDir, isSymlink: isLink,
                            uncompressedSize: isDir ? 0 : size, compressedSize: nil, modificationDate: mtime,
                            posixPermissions: perm == 0 ? nil : perm, isEncrypted: archive_entry_is_encrypted(e) != 0,
                            method: nil, crc32: nil, linkTarget: target, hardLinkTarget: hardlink)
    }

    static func rawEntryName(for archivePath: String) -> String {
        let name = URL(fileURLWithPath: archivePath).lastPathComponent
        let stripped = (name as NSString).deletingPathExtension
        return stripped.isEmpty || stripped == name ? name + ".out" : stripped
    }

    // MARK: - Scanning

    private func scan(progress: ProgressReporter?) throws {
        do {
            try scanOnce(progress: progress)
        } catch ArchiveError.notAnArchive(_) where !useRawFormat {
            // A plain compressed file (foo.txt.gz) — expose it as one entry.
            useRawFormat = true
            do { try scanOnce(progress: progress) } catch {
                useRawFormat = false
                throw ArchiveError.notAnArchive(path)
            }
            if filterCodes.isEmpty {
                useRawFormat = false
                throw ArchiveError.notAnArchive(path)
            }
        }
    }

    private func scanOnce(progress: ProgressReporter?) throws {
        let a = try openReader()
        defer { archive_read_free(a) }
        let fileSize = Int64(identity.size)
        progress?.reset(total: fileSize, phase: "Reading")
        var all: [ArchiveEntry] = []
        var encrypted = false
        while let e = try nextHeader(a) {
            let entry = makeEntry(e)
            encrypted = encrypted || entry.isEncrypted
            all.append(entry)
            archive_read_data_skip(a)
            progress?.set(completed: archive_filter_bytes(a, -1))
            try progress?.checkCancelled()
        }
        if archive_read_has_encrypted_entries(a) > 0 { encrypted = true }
        formatCode = archive_format(a)
        filterCodes = (0..<archive_filter_count(a)).map { archive_filter_code(a, $0) }.filter { $0 != LA.filterNone }
        headers = all

        // Unique by path, last one wins (tar appends updates).
        var index: [String: Int] = [:]
        var unique: [ArchiveEntry] = []
        for entry in all where !entry.path.isEmpty {
            if let i = index[entry.path] { unique[i] = entry } else {
                index[entry.path] = unique.count
                unique.append(entry)
            }
        }
        entries = unique
        isEncrypted = encrypted
        format = resolveFormat()
        editingMode = resolveEditingMode()
        notes = []
        if case .streamRewrite(true) = editingMode {
            notes.append("Changes to \(format.displayName) archives are applied by re-streaming the archive: the outer compression is redone, but nothing is extracted to disk.")
        }
        if editingMode == .readOnly, !forceReadOnly {
            notes.append("\(format.displayName) archives are read-only. You can browse, preview and extract individual items.")
        }
    }

    private func resolveFormat() -> ArchiveFormat {
        let base = formatCode & LA.baseMask
        if filterCodes.contains(LA.rpm) { return .rpm }
        let filter = filterCodes.first
        if base == LA.tar || (base == LA.empty && ArchiveFormat.guess(fromFilename: path)?.isTarFamily == true) {
            switch filter {
            case nil: return .tar
            case LA.gzip?: return .tarGzip
            case LA.bzip2?: return .tarBzip2
            case LA.xz?: return .tarXz
            case LA.zstd?: return .tarZstd
            case LA.lz4?: return .tarLz4
            case LA.lzma?: return .tarLzma
            case LA.lzip?: return .tarLzip
            case LA.compress?: return .tarCompress
            default: return .tar
            }
        }
        if useRawFormat || base == LA.raw {
            switch filter {
            case LA.gzip?: return .gzip
            case LA.bzip2?: return .bzip2
            case LA.xz?: return .xz
            case LA.zstd?: return .zstd
            case LA.lz4?: return .lz4
            default: return .other
            }
        }
        switch base {
        case LA.zip: return .zip
        case LA.sevenZip: return .sevenZip
        case LA.rar: return .rar
        case LA.rar5: return .rar5
        case LA.iso9660: return .iso9660
        case LA.cab: return .cab
        case LA.xar: return .xar
        case LA.cpio: return .cpio
        case LA.lha: return .lha
        case LA.ar: return .ar
        case LA.warc: return .warc
        case LA.mtree: return .mtree
        default: return ArchiveFormat.guess(fromFilename: path) ?? .other
        }
    }

    private func resolveEditingMode() -> EditingMode {
        guard !forceReadOnly, format.isTarFamily, filterCodes.count <= 1,
              filterCodes.allSatisfy({ LA.writableFilters.contains($0) }) else { return .readOnly }
        return .streamRewrite(recompresses: !filterCodes.isEmpty)
    }

    var statistics: ArchiveStatistics {
        ArchiveStatistics(fileCount: entries.filter { !$0.isDirectory }.count,
                          folderCount: entries.filter(\.isDirectory).count,
                          totalUncompressed: entries.reduce(0) { $0 + $1.uncompressedSize },
                          totalCompressed: nil,
                          archiveSize: identity.size,
                          reclaimableBytes: 0)
    }

    // MARK: - Extraction

    func extract(where select: (ArchiveEntry) -> Bool, open: (ArchiveEntry) throws -> DataSink?,
                 progress: ProgressReporter?) throws {
        guard try FileIdentity(path: path) == identity else { throw ArchiveError.modifiedExternally }
        let a = try openReader()
        defer { archive_read_free(a) }
        let wanted = headers.filter(select)
        progress?.reset(total: Int64(wanted.reduce(0) { $0 + $1.uncompressedSize }), phase: "Extracting")
        var remaining = wanted.count
        while remaining > 0, let e = try nextHeader(a) {
            try progress?.checkCancelled()
            let entry = makeEntry(e)
            guard select(entry) else {
                archive_read_data_skip(a)
                continue
            }
            remaining -= 1
            guard let sink = try open(entry) else {
                archive_read_data_skip(a)
                continue
            }
            if !entry.isDirectory, !entry.isSymlink {
                try copyData(from: a, entry: entry.path, into: ProgressSink(next: sink, progress: progress))
            }
            try sink.finish()
        }
    }

    private func copyData(from a: OpaquePointer, entry: String, into sink: DataSink) throws {
        var buffer: UnsafeRawPointer?
        var size = 0
        var offset: la_int64_t = 0
        var position: Int64 = 0
        let zeros = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let status = archive_read_data_block(a, &buffer, &size, &offset)
            if status == ARCHIVE_EOF { return }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else { throw translate(message(a), entry: entry) }
            // Sparse files: materialise holes.
            while position < offset {
                let n = Int(min(Int64(zeros.count), offset - position))
                try zeros.withUnsafeBytes { try sink.write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                position += Int64(n)
            }
            if size > 0, let buffer {
                try sink.write(UnsafeRawBufferPointer(start: buffer, count: size))
                position += Int64(size)
            }
        }
    }

    // MARK: - Streaming rewrite

    func apply(_ changes: [ArchiveChange], options: WriteOptions, progress: ProgressReporter?) throws {
        guard editingMode.isEditable else { throw ArchiveError.readOnly(format: format.displayName) }
        guard options.encryption == .none else {
            throw ArchiveError.unsupported("encryption is only available for ZIP archives")
        }
        guard try FileIdentity(path: path) == identity else { throw ArchiveError.modifiedExternally }

        var plan = EditPlan(existing: headers.map { ($0.path, $0.isDirectory) }, options: options)
        for change in changes { try plan.apply(change) }
        guard plan.hasChanges else { return }

        let renames = Dictionary(plan.survivors.compactMap { item in item.original.map { (headers[$0].path, item.path) } },
                                 uniquingKeysWith: { _, last in last })
        let additions = plan.survivors.compactMap(\.addition)
        progress?.reset(total: Int64(identity.size) + Int64(additions.reduce(0) { $0 + $1.source.size }),
                        phase: "Rewriting archive")

        let tmp = temporarySibling(of: path)
        do {
            let reader = try openReader()
            defer { archive_read_free(reader) }
            let writer = try Self.makeWriter(formatCode: formatCode & LA.baseMask == LA.tar ? formatCode : LA.paxRestricted,
                                             filters: filterCodes, level: options.compressionLevel)
            defer { archive_write_free(writer) }
            guard archive_write_open_filename(writer, tmp) == ARCHIVE_OK else { throw ArchiveError.libarchive(message(writer)) }

            var index = 0
            while let e = try nextHeader(reader) {
                defer { index += 1 }
                try progress?.checkCancelled()
                progress?.set(completed: archive_filter_bytes(reader, -1))
                guard let item = plan.survivor(forOriginal: index) else {
                    archive_read_data_skip(reader)
                    continue
                }
                if item.renamed {
                    let isDir = UInt32(archive_entry_filetype(e)) == LA.directory
                    archive_entry_set_pathname_utf8(e, isDir ? item.path + "/" : item.path)
                }
                if let link = archive_entry_hardlink_utf8(e).map({ ArchivePath.display(String(cString: $0)) }),
                   let renamed = renames[link], renamed != link {
                    archive_entry_set_hardlink_utf8(e, renamed)
                }
                guard archive_write_header(writer, e) == ARCHIVE_OK else { throw ArchiveError.libarchive(message(writer)) }
                if archive_entry_size(e) > 0 {
                    try copyData(from: reader, entry: item.path, into: ArchiveWriterSink(writer))
                }
                archive_write_finish_entry(writer)
            }
            for addition in additions {
                try Self.write(addition, to: writer, progress: progress)
            }
            guard archive_write_close(writer) == ARCHIVE_OK else { throw ArchiveError.libarchive(message(writer)) }
            try atomicReplace(path, with: tmp)
        } catch {
            unlink(tmp)
            throw error
        }
        identity = try FileIdentity(path: path)
        try scan(progress: nil)
    }

    func compact(progress: ProgressReporter?) throws {}

    static func makeWriter(formatCode: Int32, filters: [Int32], level: Int) throws -> OpaquePointer {
        guard let w = archive_write_new() else { throw ArchiveError.libarchive("Out of memory") }
        if archive_write_set_format(w, formatCode) != ARCHIVE_OK {
            archive_write_set_format_pax_restricted(w)
        }
        for code in filters {
            guard archive_write_add_filter(w, code) == ARCHIVE_OK else {
                let text = message(w)
                archive_write_free(w)
                throw ArchiveError.unsupported("writing this compression (\(text))")
            }
        }
        if !filters.isEmpty {
            // Not every filter knows every level; failures here are harmless.
            archive_write_set_filter_option(w, nil, "compression-level", String(max(1, min(9, level))))
        }
        return w
    }

    private static func write(_ a: PendingAddition, to writer: OpaquePointer, progress: ProgressReporter?) throws {
        guard let e = archive_entry_new() else { throw ArchiveError.libarchive("Out of memory") }
        defer { archive_entry_free(e) }
        archive_entry_set_pathname_utf8(e, a.isDirectory ? a.path + "/" : a.path)
        archive_entry_set_mtime(e, time_t(a.modified.timeIntervalSince1970), 0)
        switch a.source {
        case .directory:
            archive_entry_set_filetype(e, LA.directory)
            archive_entry_set_perm(e, mode_t(a.mode & 0o7777))
        case let .symlink(target):
            archive_entry_set_filetype(e, LA.symlink)
            archive_entry_set_perm(e, 0o755)
            archive_entry_set_symlink_utf8(e, target)
        case .file, .data:
            archive_entry_set_filetype(e, LA.regular)
            archive_entry_set_perm(e, mode_t(a.mode & 0o7777))
            archive_entry_set_size(e, la_int64_t(a.source.size))
        }
        guard archive_write_header(writer, e) == ARCHIVE_OK else { throw ArchiveError.libarchive(message(writer)) }
        switch a.source {
        case .file, .data:
            try feed(a.source, into: ProgressSink(next: ArchiveWriterSink(writer), progress: progress))
        default:
            break
        }
        archive_write_finish_entry(writer)
    }

    /// Writes an empty archive of `format` (tar family only).
    static func createEmpty(path: String, format: ArchiveFormat) throws {
        let filter: Int32? = switch format {
        case .tar: nil
        case .tarGzip: LA.gzip
        case .tarBzip2: LA.bzip2
        case .tarXz: LA.xz
        case .tarZstd: LA.zstd
        case .tarLz4: LA.lz4
        case .tarLzma: LA.lzma
        case .tarLzip: LA.lzip
        case .tarCompress: LA.compress
        default: throw ArchiveError.unsupported("creating \(format.displayName) archives")
        }
        guard !FileManager.default.fileExists(atPath: path) else { throw ArchiveError.entryExists(path) }
        let w = try makeWriter(formatCode: LA.paxRestricted, filters: filter.map { [$0] } ?? [], level: 6)
        defer { archive_write_free(w) }
        guard archive_write_open_filename(w, path) == ARCHIVE_OK, archive_write_close(w) == ARCHIVE_OK else {
            throw ArchiveError.libarchive(message(w))
        }
    }
}

private final class ArchiveWriterSink: DataSink {
    private let writer: OpaquePointer

    init(_ writer: OpaquePointer) { self.writer = writer }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        guard chunk.count > 0 else { return }
        let written = archive_write_data(writer, chunk.baseAddress, chunk.count)
        guard written >= 0 else { throw ArchiveError.libarchive(message(writer)) }
    }

    func finish() throws {}
}
