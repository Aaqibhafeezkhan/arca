import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// ZIP engine with true in-place editing.
///
/// Commit strategy: the central directory is always last, so new and moved
/// entries are written starting where the old central directory began,
/// followed by a fresh central directory. Untouched entries are never read or
/// rewritten; deleted ones simply stop being referenced (reclaimable with
/// `compact()`, itself a raw byte copy — nothing is ever recompressed).
final class ZipArchive: ArchiveBackend {
    let path: String
    private let journal: JournalStore

    private(set) var records: [ZipRecord] = []
    private var archiveComment: [UInt8] = []
    /// physical offset = logical offset + delta (non-zero for some SFX stubs).
    private var delta: UInt64 = 0
    private(set) var centralDirectoryStart: UInt64 = 0
    private var prefixEnd: UInt64 = 0
    private var identity: FileIdentity
    private var reader: RandomAccessFile
    private var dataStartCache: [UInt64: UInt64] = [:]
    private var fallback: ArchiveBackend?

    var passwords: [String] = [] { didSet { fallback?.passwords = passwords } }
    /// Test hook: throws at named commit stages to simulate crashes.
    var faultInjector: ((String) throws -> Void)?

    let format: ArchiveFormat = .zip
    let editingMode: EditingMode = .inPlace
    private(set) var entries: [ArchiveEntry] = []
    private(set) var notes: [String] = []

    var isEncrypted: Bool { records.contains { $0.encryption != .none } }

    init(path: String, journal: JournalStore) throws {
        self.path = path
        self.journal = journal
        try journal.recoverIfNeeded(archivePath: path)
        reader = try RandomAccessFile(path: path, writable: false)
        identity = try FileIdentity(path: path)
        try load()
    }

    /// Creates an empty archive (just an end-of-central-directory record).
    static func create(path: String, journal: JournalStore) throws -> ZipArchive {
        let file = try RandomAccessFile(path: path, writable: true, create: true)
        var w = ByteWriter()
        w.u32(ZipSignature.endOfCentralDirectory)
        for _ in 0..<4 { w.u16(0) }
        w.u32(0)
        w.u32(0)
        w.u16(0)
        try file.write(w.bytes, at: 0)
        try file.sync()
        return try ZipArchive(path: path, journal: journal)
    }

    // MARK: - Loading

    private func load() throws {
        let size = try reader.size()
        guard size >= 22 else { throw ArchiveError.notAnArchive(path) }
        let tailLength = Int(min(size, 22 + 0xFFFF + 20 + 56))
        let tailStart = size - UInt64(tailLength)
        let tail = try reader.readExactly(at: tailStart, count: tailLength)

        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.le32(at: i) == ZipSignature.endOfCentralDirectory,
               i + 22 + Int(tail.le16(at: i + 20)) <= tail.count {
                eocd = i
                break
            }
            i -= 1
        }
        guard let e = eocd else { throw ArchiveError.notAnArchive(path) }

        var r = ByteReader(tail, offset: e + 4)
        let disk = try r.u16()
        let cdDisk = try r.u16()
        _ = try r.u16()
        var count = UInt64(try r.u16())
        var cdSize = UInt64(try r.u32())
        var cdOffset = UInt64(try r.u32())
        let commentLength = Int(try r.u16())
        archiveComment = try r.take(commentLength)
        guard disk == 0 || disk == 0xFFFF, cdDisk == 0 || cdDisk == 0xFFFF else {
            throw ArchiveError.unsupported("multi-volume ZIP archives")
        }

        let eocdPhysical = tailStart + UInt64(e)
        var cdEnd = eocdPhysical
        if e >= 20, tail.le32(at: e - 20) == ZipSignature.zip64Locator {
            var l = ByteReader(tail, offset: e - 12)
            let storedOffset = try l.u64()
            let locatorPhysical = eocdPhysical - 20
            for candidate in [storedOffset, locatorPhysical >= 56 ? locatorPhysical - 56 : storedOffset] {
                let rec = try reader.read(at: candidate, count: 56)
                guard rec.count == 56, rec.le32(at: 0) == ZipSignature.zip64EndOfCentralDirectory else { continue }
                var z = ByteReader(rec, offset: 24)
                _ = try z.u64()
                count = try z.u64()
                cdSize = try z.u64()
                cdOffset = try z.u64()
                cdEnd = candidate
                break
            }
        }

        guard cdSize <= cdEnd else { throw ArchiveError.corrupted("central directory size out of range") }
        var cdPhysical = cdEnd - cdSize
        if count > 0 {
            let sigAtComputed = try reader.read(at: cdPhysical, count: 4)
            if sigAtComputed.count < 4 || sigAtComputed.le32(at: 0) != ZipSignature.centralFile {
                let sigAtStored = try reader.read(at: cdOffset, count: 4)
                guard sigAtStored.count == 4, sigAtStored.le32(at: 0) == ZipSignature.centralFile else {
                    throw ArchiveError.corrupted("central directory not found")
                }
                cdPhysical = cdOffset
            }
        }
        delta = cdPhysical >= cdOffset ? cdPhysical - cdOffset : 0
        centralDirectoryStart = cdPhysical

        let cd = try reader.readExactly(at: cdPhysical, count: Int(cdSize))
        var parsed: [ZipRecord] = []
        parsed.reserveCapacity(Int(min(count, 1_000_000)))
        var c = ByteReader(cd)
        while c.remaining >= 46 {
            guard try c.u32() == ZipSignature.centralFile else { break }
            parsed.append(try Self.parseRecord(&c))
        }

        // Duplicate names: the last one wins (as with most extractors).
        var seen: [String: Int] = [:]
        var unique: [ZipRecord] = []
        for var rec in parsed {
            rec.path = rec.decodedPath()
            guard !rec.path.isEmpty else { continue }
            if let previous = seen[rec.path] { unique[previous] = rec } else {
                seen[rec.path] = unique.count
                unique.append(rec)
            }
        }
        records = unique
        prefixEnd = records.map { $0.localHeaderOffset + delta }.min() ?? cdPhysical
        dataStartCache.removeAll()
        rebuildEntries()
        detectNotes()
    }

    private static func parseRecord(_ c: inout ByteReader) throws -> ZipRecord {
        let versionMadeBy = try c.u16()
        let versionNeeded = try c.u16()
        let flags = try c.u16()
        let method = try c.u16()
        let time = try c.u16()
        let date = try c.u16()
        let crc = try c.u32()
        var csize = UInt64(try c.u32())
        var usize = UInt64(try c.u32())
        let nameLength = Int(try c.u16())
        let extraLength = Int(try c.u16())
        let commentLength = Int(try c.u16())
        var diskStart = UInt32(try c.u16())
        let internalAttributes = try c.u16()
        let externalAttributes = try c.u32()
        var offset = UInt64(try c.u32())
        let name = try c.take(nameLength)
        let extra = ZipExtraField.parse(try c.take(extraLength))
        let comment = try c.take(commentLength)

        if let z = extra.first(ZipExtraID.zip64) {
            var zr = ByteReader(z.data)
            if usize == zip32Max, let v = try? zr.u64() { usize = v }
            if csize == zip32Max, let v = try? zr.u64() { csize = v }
            if offset == zip32Max, let v = try? zr.u64() { offset = v }
            if diskStart == 0xFFFF, let v = try? zr.u32() { diskStart = v }
        }
        return ZipRecord(versionMadeBy: versionMadeBy, versionNeeded: versionNeeded, flags: flags, method: method,
                         dosTime: time, dosDate: date, crc32: crc, compressedSize: csize, uncompressedSize: usize,
                         diskStart: diskStart, internalAttributes: internalAttributes,
                         externalAttributes: externalAttributes, localHeaderOffset: offset, nameBytes: name,
                         extraFields: extra.removing([ZipExtraID.zip64]), comment: comment)
    }

    private func rebuildEntries() {
        entries = records.map { $0.entry() }
    }

    private func detectNotes() {
        var notes: [String] = []
        let paths = Set(records.map(\.path))
        if paths.contains("META-INF/MANIFEST.MF"),
           paths.contains(where: { $0.hasPrefix("META-INF/") && ($0.hasSuffix(".SF") || $0.hasSuffix(".RSA") || $0.hasSuffix(".EC")) }) {
            notes.append("This JAR is signed. Editing it invalidates the signature.")
        }
        if centralDirectoryStart >= 16,
           let magic = try? reader.read(at: centralDirectoryStart - 16, count: 16),
           magic == Array("APK Sig Block 42".utf8) {
            notes.append("This APK has a v2+ signature. Editing it invalidates the signature.")
        }
        if paths.contains(where: { $0.hasPrefix("Payload/") && $0.contains(".app/_CodeSignature/") }) {
            notes.append("This IPA is code-signed. Editing it invalidates the signature.")
        }
        if records.contains(where: { $0.encryption == .zipCrypto }) {
            notes.append("Some entries use legacy ZipCrypto encryption, which is weak. Re-add them to protect them with AES-256.")
        }
        self.notes = notes
    }

    private func checkUnchanged() throws {
        guard try FileIdentity(path: path) == identity else { throw ArchiveError.modifiedExternally }
    }

    // MARK: - Statistics

    var statistics: ArchiveStatistics {
        let size = (try? reader.size()) ?? 0
        var live: UInt64 = 0
        for r in records {
            live += 30 + UInt64(r.nameBytes.count) + UInt64(r.extraFields.serialized().count) + r.compressedSize
            if r.flags & ZipFlag.dataDescriptor != 0 { live += 16 }
        }
        let region = centralDirectoryStart > prefixEnd ? centralDirectoryStart - prefixEnd : 0
        let waste = region > live ? region - live : 0
        return ArchiveStatistics(
            fileCount: records.filter { !$0.isDirectory }.count,
            folderCount: records.filter(\.isDirectory).count,
            totalUncompressed: records.reduce(0) { $0 + $1.uncompressedSize },
            totalCompressed: records.reduce(0) { $0 + $1.compressedSize },
            archiveSize: size,
            // Below 4 KiB it's header slack, not something worth compacting.
            reclaimableBytes: waste > 4096 ? waste : 0
        )
    }

    // MARK: - Extraction

    private func dataStart(of record: ZipRecord) throws -> UInt64 {
        let physical = record.localHeaderOffset + delta
        if let cached = dataStartCache[physical] { return cached }
        let header = try reader.readExactly(at: physical, count: 30)
        guard header.le32(at: 0) == ZipSignature.localFile else {
            throw ArchiveError.corrupted("missing local header for \(record.path)")
        }
        let start = physical + 30 + UInt64(header.le16(at: 26)) + UInt64(header.le16(at: 28))
        dataStartCache[physical] = start
        return start
    }

    func extract(where select: (ArchiveEntry) -> Bool, open: (ArchiveEntry) throws -> DataSink?,
                 progress: ProgressReporter?) throws {
        try checkUnchanged()
        let selected = records.indices.filter { select(entries[$0]) }
        progress?.reset(total: Int64(selected.reduce(0) { $0 + records[$1].uncompressedSize }), phase: "Extracting")
        for i in selected {
            try progress?.checkCancelled()
            guard let sink = try open(entries[i]) else { continue }
            try extract(records[i], into: ProgressSink(next: sink, progress: progress))
        }
    }

    private func extract(_ record: ZipRecord, into sink: DataSink) throws {
        if record.isDirectory {
            try sink.finish()
            return
        }
        let method = record.effectiveMethod
        guard method == ZipMethod.store || method == ZipMethod.deflate else {
            try extractWithFallback(record, into: sink)
            return
        }
        let start = try dataStart(of: record)
        guard start + record.compressedSize <= (try reader.size()) else {
            throw ArchiveError.corrupted("entry \(record.path) extends past end of file")
        }

        let encryption = record.encryption
        var verifyCRC = true
        if case let .aes(_, vendorVersion, _) = encryption, vendorVersion == 2 { verifyCRC = false }
        let verifier = CRCVerifySink(expected: record.crc32, size: record.uncompressedSize, enabled: verifyCRC,
                                     entry: record.path, next: sink)
        let decoder: DataSink = method == ZipMethod.deflate ? try InflateSink(next: verifier) : verifier

        do {
            switch encryption {
            case .none:
                try pump(reader, from: start, length: record.compressedSize, into: decoder)
                try decoder.finish()

            case .zipCrypto:
                guard record.compressedSize >= 12 else { throw ArchiveError.corrupted("encrypted entry too short") }
                let header = try reader.readExactly(at: start, count: 12)
                let timeCheck = UInt8(record.dosTime >> 8)
                let crcCheck = UInt8(record.crc32 >> 24)
                var chosen: ZipCryptoKeys?
                for password in passwords {
                    var keys = ZipCryptoKeys(password: Array(password.utf8))
                    var last: UInt8 = 0
                    for b in header { last = keys.decrypt(b) }
                    if last == crcCheck || (record.flags & ZipFlag.dataDescriptor != 0 && last == timeCheck) {
                        chosen = keys
                        break
                    }
                }
                guard let keys = chosen else {
                    throw passwords.isEmpty ? ArchiveError.passwordRequired(entry: record.path) : .wrongPassword(entry: record.path)
                }
                let decrypt = ZipCryptoDecryptSink(keys: keys, next: decoder)
                try pump(reader, from: start + 12, length: record.compressedSize - 12, into: decrypt)
                try decrypt.finish()

            case let .aes(strength, _, _):
                let overhead = UInt64(strength.saltLength + 2 + WinZipAESKeys.macLength)
                guard record.compressedSize >= overhead else { throw ArchiveError.corrupted("encrypted entry too short") }
                let header = try reader.readExactly(at: start, count: strength.saltLength + 2)
                let salt = Array(header.prefix(strength.saltLength))
                let check = Array(header.suffix(2))
                let payload = record.compressedSize - overhead
                let mac = try reader.readExactly(at: start + UInt64(header.count) + payload, count: WinZipAESKeys.macLength)
                guard let keys = passwords.lazy
                    .map({ WinZipAESKeys(password: Array($0.utf8), salt: salt, strength: strength) })
                    .first(where: { $0.verifier == check }) else {
                    throw passwords.isEmpty ? ArchiveError.passwordRequired(entry: record.path) : .wrongPassword(entry: record.path)
                }
                let decrypt = try AESDecryptSink(keys: keys, expectedMAC: mac, entry: record.path, next: decoder)
                try pump(reader, from: start + UInt64(header.count), length: payload, into: decrypt)
                try decrypt.finish()

            case .unsupported:
                throw ArchiveError.unsupported("strong encryption (\(record.path))")
            }
        } catch ArchiveError.checksumMismatch(let entry) where encryption == .zipCrypto {
            // 1-in-256 false positives on the header check byte.
            throw ArchiveError.wrongPassword(entry: entry)
        }
    }

    private func extractWithFallback(_ record: ZipRecord, into sink: DataSink) throws {
        if fallback == nil {
            // 7-Zip handles every ZIP method (Deflate64, PPMd, LZMA, …);
            // libarchive covers bzip2/lzma/xz/zstd when it isn't available.
            if let tool = ExternalTools.sevenZip {
                fallback = try SevenZipBackend(path: path, passwords: passwords, tool: tool)
            } else {
                fallback = try LibArchiveBackend(path: path, passwords: passwords, forceReadOnly: true)
            }
        }
        var found = false
        try fallback!.extract(where: { $0.path == record.path }, open: { _ in
            found = true
            return sink
        }, progress: nil)
        if !found { throw ArchiveError.unsupported("\(ZipMethod.name(record.effectiveMethod)) compression") }
    }

    // MARK: - Editing

    func apply(_ changes: [ArchiveChange], options: WriteOptions, progress: ProgressReporter?) throws {
        try checkUnchanged()
        var plan = EditPlan(existing: records.map { ($0.path, $0.isDirectory) }, options: options)
        for change in changes { try plan.apply(change) }
        guard plan.hasChanges else { return }

        let survivors = plan.survivors
        let total = survivors.reduce(UInt64(0)) { sum, item in
            if let a = item.addition { return sum + a.source.size }
            return item.renamed ? sum + records[item.original!].compressedSize : sum
        }
        progress?.reset(total: Int64(total), phase: "Updating archive")

        // Pathological layout (entry data after the central directory): rewrite.
        if records.contains(where: { $0.localHeaderOffset + delta >= centralDirectoryStart }) {
            try rewrite(survivors, options: options, progress: progress)
            return
        }

        let file = try RandomAccessFile(path: path, writable: true)
        let originalSize = try file.size()
        let tail = try file.readExactly(at: centralDirectoryStart, count: Int(originalSize - centralDirectoryStart))
        let token = try journal.begin(archivePath: path, originalSize: originalSize,
                                      tailOffset: centralDirectoryStart, tail: tail)
        do {
            var cursor = centralDirectoryStart
            var newRecords: [ZipRecord] = []
            newRecords.reserveCapacity(survivors.count)
            for item in survivors {
                if let addition = item.addition {
                    newRecords.append(try writeAddition(addition, to: file, at: &cursor, options: options, progress: progress))
                } else {
                    var record = records[item.original!]
                    if item.renamed {
                        rename(&record, to: item.path, isDirectory: item.isDirectory)
                        try relocate(&record, from: reader, to: file, at: &cursor, progress: progress)
                    }
                    newRecords.append(record)
                }
                try faultInjector?("entry")
            }
            try faultInjector?("centralDirectory")
            let end = try writeCentralDirectory(newRecords, to: file, at: cursor)
            try file.truncate(to: end)
            try faultInjector?("sync")
            try file.sync()
            journal.end(token)
            try reloadAfterWrite()
        } catch {
            try? journal.rollback(token, archivePath: path)
            identity = (try? FileIdentity(path: path)) ?? identity
            throw error
        }
    }

    func compact(progress: ProgressReporter?) throws {
        try checkUnchanged()
        let survivors = records.indices.map {
            EditPlan.Item(original: $0, path: records[$0].path, isDirectory: records[$0].isDirectory)
        }
        progress?.reset(total: Int64(records.reduce(0) { $0 + $1.compressedSize }), phase: "Compacting")
        try rewrite(survivors, options: .default, progress: progress)
    }

    /// Writes a fresh archive next to the original and atomically swaps it in.
    /// Existing entries are copied raw (no recompression).
    private func rewrite(_ items: [EditPlan.Item], options: WriteOptions, progress: ProgressReporter?) throws {
        let tmp = temporarySibling(of: path)
        do {
            let out = try RandomAccessFile(path: tmp, writable: true, create: true)
            var cursor: UInt64 = 0
            if prefixEnd > 0 {
                let stub = RegionSink(file: out, start: 0)
                try pump(reader, from: 0, length: prefixEnd, into: stub)
                cursor = prefixEnd
            }
            var newRecords: [ZipRecord] = []
            for item in items {
                if let addition = item.addition {
                    newRecords.append(try writeAddition(addition, to: out, at: &cursor, options: options, progress: progress))
                } else {
                    var record = records[item.original!]
                    if item.renamed { rename(&record, to: item.path, isDirectory: item.isDirectory) }
                    try relocate(&record, from: reader, to: out, at: &cursor, progress: progress)
                    newRecords.append(record)
                }
            }
            let end = try writeCentralDirectory(newRecords, to: out, at: cursor)
            try out.truncate(to: end)
            try out.sync()
            try atomicReplace(path, with: tmp)
        } catch {
            unlink(tmp)
            throw error
        }
        try reloadAfterWrite()
    }

    private func reloadAfterWrite() throws {
        reader = try RandomAccessFile(path: path, writable: false)
        identity = try FileIdentity(path: path)
        fallback = nil
        try load()
    }

    private func rename(_ record: inout ZipRecord, to path: String, isDirectory: Bool) {
        var name = Array(path.utf8)
        if isDirectory { name.append(UInt8(ascii: "/")) }
        record.nameBytes = name
        record.path = path
        if name.contains(where: { $0 >= 0x80 }) { record.flags |= ZipFlag.utf8 }
        record.extraFields = record.extraFields.removing([ZipExtraID.unicodePath])
    }

    /// Copies an entry's compressed bytes verbatim under a new local header.
    private func relocate(_ record: inout ZipRecord, from source: RandomAccessFile, to dest: RandomAccessFile,
                          at cursor: inout UInt64, progress: ProgressReporter?) throws {
        let physical = record.localHeaderOffset + delta
        let header = try source.readExactly(at: physical, count: 30)
        guard header.le32(at: 0) == ZipSignature.localFile else {
            throw ArchiveError.corrupted("missing local header for \(record.path)")
        }
        let oldName = Int(header.le16(at: 26))
        let oldExtraLength = Int(header.le16(at: 28))
        let oldExtra = ZipExtraField.parse(try source.readExactly(at: physical + 30 + UInt64(oldName), count: oldExtraLength))
        let dataStart = physical + 30 + UInt64(oldName) + UInt64(oldExtraLength)

        let usesDescriptor = record.flags & ZipFlag.dataDescriptor != 0
        let zip64 = record.compressedSize >= zip32Max || record.uncompressedSize >= zip32Max
        var extra = oldExtra.removing([ZipExtraID.zip64, ZipExtraID.unicodePath])
        if zip64 {
            var z = ByteWriter()
            z.u64(usesDescriptor ? 0 : record.uncompressedSize)
            z.u64(usesDescriptor ? 0 : record.compressedSize)
            extra.insert(ZipExtraField(id: ZipExtraID.zip64, data: z.bytes), at: 0)
        }
        if zip64 { record.versionNeeded = max(record.versionNeeded, 45) }

        let lfh = localHeader(record, extra: extra, crc: usesDescriptor ? 0 : record.crc32,
                              compressedSize: usesDescriptor ? 0 : record.compressedSize,
                              uncompressedSize: usesDescriptor ? 0 : record.uncompressedSize, zip64: zip64)
        let newOffset = cursor
        try dest.write(lfh, at: cursor)
        cursor += UInt64(lfh.count)
        let region = RegionSink(file: dest, start: cursor)
        try pump(source, from: dataStart, length: record.compressedSize, into: ProgressSink(next: region, progress: progress))
        cursor += record.compressedSize

        if usesDescriptor {
            var dd = ByteWriter()
            dd.u32(ZipSignature.dataDescriptor)
            dd.u32(record.crc32)
            if zip64 {
                dd.u64(record.compressedSize)
                dd.u64(record.uncompressedSize)
            } else {
                dd.u32(UInt32(record.compressedSize))
                dd.u32(UInt32(record.uncompressedSize))
            }
            try dest.write(dd.bytes, at: cursor)
            cursor += UInt64(dd.bytes.count)
        }
        record.localHeaderOffset = newOffset - delta
    }

    private func localHeader(_ r: ZipRecord, extra: [ZipExtraField], crc: UInt32, compressedSize: UInt64,
                             uncompressedSize: UInt64, zip64: Bool) -> [UInt8] {
        let extraBytes = extra.serialized()
        var w = ByteWriter(capacity: 30 + r.nameBytes.count + extraBytes.count)
        w.u32(ZipSignature.localFile)
        w.u16(r.versionNeeded)
        w.u16(r.flags)
        w.u16(r.method)
        w.u16(r.dosTime)
        w.u16(r.dosDate)
        w.u32(crc)
        w.u32(zip64 ? UInt32.max : UInt32(compressedSize))
        w.u32(zip64 ? UInt32.max : UInt32(uncompressedSize))
        w.u16(UInt16(r.nameBytes.count))
        w.u16(UInt16(extraBytes.count))
        w.append(r.nameBytes)
        w.append(extraBytes)
        return w.bytes
    }

    private func writeAddition(_ a: PendingAddition, to file: RandomAccessFile, at cursor: inout UInt64,
                               options: WriteOptions, progress: ProgressReporter?) throws -> ZipRecord {
        let isDir = a.isDirectory
        var name = Array(a.path.utf8)
        if isDir { name.append(UInt8(ascii: "/")) }
        let (dosTime, dosDate) = DOSDateTime.components(a.modified)
        let size = a.source.size

        var password: [UInt8]?
        if case let .aes256(pw) = options.encryption, !isDir { password = Array(pw.utf8) }
        var store = isDir || a.isSymlink || size == 0 || options.compressionLevel == 0
            || (options.storeCompressedMedia && IncompressibleTypes.contains(a.path))
        if !store, size <= 4 << 20 {
            // Small enough to try: don't let deflate inflate random-looking data.
            let trial = MemorySink()
            try feed(a.source, into: try DeflateSink(next: trial, level: options.compressionLevel))
            store = UInt64(trial.data.count) >= size
        }
        let method = store ? ZipMethod.store : ZipMethod.deflate
        let zip64 = size >= 0xFFFF_0000

        var flags: UInt16 = 0
        if name.contains(where: { $0 >= 0x80 }) { flags |= ZipFlag.utf8 }
        var timestamp = ByteWriter()
        timestamp.u8(1)
        timestamp.u32(UInt32(truncatingIfNeeded: Int64(a.modified.timeIntervalSince1970)))
        var extra = [ZipExtraField(id: ZipExtraID.extendedTimestamp, data: timestamp.bytes)]
        if password != nil {
            flags |= ZipFlag.encrypted
            var aes = ByteWriter()
            aes.u16(2) // AE-2: no CRC, authenticity via HMAC
            aes.append([UInt8(ascii: "A"), UInt8(ascii: "E")])
            aes.u8(AESStrength.aes256.rawValue)
            aes.u16(method)
            extra.append(ZipExtraField(id: ZipExtraID.winZipAES, data: aes.bytes))
        }
        let versionNeeded: UInt16 = zip64 ? 45 : (password != nil ? 51 : (store && !isDir ? 10 : 20))

        let mode: UInt16 = isDir ? 0o040000 | (a.mode & 0o7777) : a.isSymlink ? 0o120755 : 0o100000 | (a.mode & 0o7777)
        var record = ZipRecord(
            versionMadeBy: 3 << 8 | 63, versionNeeded: versionNeeded, flags: flags,
            method: password != nil ? ZipMethod.aes : method, dosTime: dosTime, dosDate: dosDate, crc32: 0,
            compressedSize: 0, uncompressedSize: 0, diskStart: 0, internalAttributes: 0,
            externalAttributes: UInt32(mode) << 16 | (isDir ? 0x10 : 0), localHeaderOffset: cursor - delta,
            nameBytes: name, extraFields: extra, comment: [])
        record.path = a.path

        func localExtra(usize: UInt64, csize: UInt64) -> [ZipExtraField] {
            guard zip64 else { return extra }
            var z = ByteWriter()
            z.u64(usize)
            z.u64(csize)
            return [ZipExtraField(id: ZipExtraID.zip64, data: z.bytes)] + extra
        }

        let headerOffset = cursor
        let placeholder = localHeader(record, extra: localExtra(usize: 0, csize: 0), crc: 0, compressedSize: 0,
                                      uncompressedSize: 0, zip64: zip64)
        try file.write(placeholder, at: headerOffset)
        let region = RegionSink(file: file, start: headerOffset + UInt64(placeholder.count))

        var head: DataSink = region
        if let password { head = try AESEncryptSink(password: password, strength: .aes256, next: head) }
        if method == ZipMethod.deflate { head = try DeflateSink(next: head, level: options.compressionLevel) }
        let crc = CRC32Sink(next: head)
        try feed(a.source, into: ProgressSink(next: crc, progress: progress))

        if !zip64, region.count >= zip32Max || crc.count >= zip32Max {
            throw ArchiveError.unsupported("\(a.path) grew past 4 GB while being added")
        }
        record.crc32 = password != nil ? 0 : crc.crc
        record.compressedSize = region.count
        record.uncompressedSize = crc.count
        let final = localHeader(record, extra: localExtra(usize: crc.count, csize: region.count), crc: record.crc32,
                                compressedSize: region.count, uncompressedSize: crc.count, zip64: zip64)
        precondition(final.count == placeholder.count)
        try file.write(final, at: headerOffset)
        cursor = region.start + region.count
        return record
    }

    /// Writes central directory + (ZIP64) end records; returns the end offset.
    private func writeCentralDirectory(_ records: [ZipRecord], to file: RandomAccessFile, at start: UInt64) throws -> UInt64 {
        var w = ByteWriter(capacity: records.count * 80 + 128)
        for r in records {
            var z = ByteWriter()
            let usize32: UInt32 = r.uncompressedSize >= zip32Max ? .max : UInt32(r.uncompressedSize)
            if usize32 == .max { z.u64(r.uncompressedSize) }
            let csize32: UInt32 = r.compressedSize >= zip32Max ? .max : UInt32(r.compressedSize)
            if csize32 == .max { z.u64(r.compressedSize) }
            let offset32: UInt32 = r.localHeaderOffset >= zip32Max ? .max : UInt32(r.localHeaderOffset)
            if offset32 == .max { z.u64(r.localHeaderOffset) }
            var extra = r.extraFields
            if !z.bytes.isEmpty { extra.insert(ZipExtraField(id: ZipExtraID.zip64, data: z.bytes), at: 0) }
            let extraBytes = extra.serialized()

            w.u32(ZipSignature.centralFile)
            w.u16(r.versionMadeBy)
            w.u16(z.bytes.isEmpty ? r.versionNeeded : max(r.versionNeeded, 45))
            w.u16(r.flags)
            w.u16(r.method)
            w.u16(r.dosTime)
            w.u16(r.dosDate)
            w.u32(r.crc32)
            w.u32(csize32)
            w.u32(usize32)
            w.u16(UInt16(r.nameBytes.count))
            w.u16(UInt16(extraBytes.count))
            w.u16(UInt16(r.comment.count))
            w.u16(0)
            w.u16(r.internalAttributes)
            w.u32(r.externalAttributes)
            w.u32(offset32)
            w.append(r.nameBytes)
            w.append(extraBytes)
            w.append(r.comment)
        }
        let cdSize = UInt64(w.bytes.count)
        let cdLogical = start - delta
        let count = UInt64(records.count)
        if count >= 0xFFFF || cdSize >= zip32Max || cdLogical >= zip32Max {
            let zip64Logical = cdLogical + cdSize
            w.u32(ZipSignature.zip64EndOfCentralDirectory)
            w.u64(44)
            w.u16(3 << 8 | 63)
            w.u16(45)
            w.u32(0)
            w.u32(0)
            w.u64(count)
            w.u64(count)
            w.u64(cdSize)
            w.u64(cdLogical)
            w.u32(ZipSignature.zip64Locator)
            w.u32(0)
            w.u64(zip64Logical)
            w.u32(1)
        }
        w.u32(ZipSignature.endOfCentralDirectory)
        w.u16(0)
        w.u16(0)
        w.u16(UInt16(min(count, 0xFFFF)))
        w.u16(UInt16(min(count, 0xFFFF)))
        w.u32(cdSize >= zip32Max ? .max : UInt32(cdSize))
        w.u32(cdLogical >= zip32Max ? .max : UInt32(cdLogical))
        w.u16(UInt16(archiveComment.count))
        w.append(archiveComment)
        try file.write(w.bytes, at: start)
        return start + UInt64(w.bytes.count)
    }
}

/// Verifies CRC-32 and size once the stream ends.
final class CRCVerifySink: DataSink {
    private let expected: UInt32
    private let size: UInt64
    private let enabled: Bool
    private let entry: String
    private let next: DataSink
    private var crc: UInt32 = 0
    private var count: UInt64 = 0

    init(expected: UInt32, size: UInt64, enabled: Bool, entry: String, next: DataSink) {
        self.expected = expected
        self.size = size
        self.enabled = enabled
        self.entry = entry
        self.next = next
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        if enabled { crc = CRC32.update(crc, chunk) }
        count += UInt64(chunk.count)
        try next.write(chunk)
    }

    func finish() throws {
        if enabled, crc != expected || count != size { throw ArchiveError.checksumMismatch(entry: entry) }
        try next.finish()
    }
}
