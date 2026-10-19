import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Archives driven through 7-Zip's `7zz` (listing, extraction, 7z updates)
/// and, for RAR updates, RARLAB's `rar`.
///
/// Edits are applied to a clone of the archive (APFS clonefile, so instant)
/// and swapped in atomically, so a failed or cancelled batch never leaves a
/// half-updated archive. 7-Zip and RAR both copy the packed data of untouched
/// files; only solid blocks that contain changed files get recompressed.
final class SevenZipBackend: ArchiveBackend {
    let path: String
    private let tool: URL
    private var identity: FileIdentity

    private(set) var format: ArchiveFormat = .other
    private(set) var editingMode: EditingMode = .readOnly
    private(set) var entries: [ArchiveEntry] = []
    private(set) var notes: [String] = []
    private(set) var isEncrypted = false
    var passwords: [String]

    private var isSolid = false
    private var typeName = ""

    init(path: String, passwords: [String], tool: URL) throws {
        self.path = path
        self.passwords = passwords
        self.tool = tool
        identity = try FileIdentity(path: path)
        try scan()
    }

    private var password: String? { passwords.last }
    private var passwordArgument: String { "-p" + (password ?? "") }

    // MARK: - Listing

    private func scan() throws {
        let result = try ToolRunner.run(tool, ["l", "-slt", "-sccUTF-8", passwordArgument, path])
        try check(result, entry: "")
        let listing = Self.parseListing(String(decoding: result.stdout, as: UTF8.self))
        typeName = listing.properties["Type"] ?? ""
        isSolid = listing.properties["Solid"] == "+"

        var index: [String: Int] = [:]
        var unique: [ArchiveEntry] = []
        for entry in listing.entries where !entry.path.isEmpty {
            if let i = index[entry.path] { unique[i] = entry } else {
                index[entry.path] = unique.count
                unique.append(entry)
            }
        }
        entries = unique
        isEncrypted = listing.properties["Encrypted"] == "+" || unique.contains(where: \.isEncrypted)
            || !passwords.isEmpty && listing.headersEncrypted
        format = Self.format(forType: typeName, path: path)

        notes = []
        switch format {
        case .sevenZip:
            editingMode = .streamRewrite(recompresses: isSolid)
            if isSolid {
                notes.append("This 7z archive is solid: changing an item recompresses the block that contains it. Untouched blocks are copied as-is.")
            }
        case .rar, .rar5:
            if ExternalTools.rar != nil {
                editingMode = .streamRewrite(recompresses: isSolid)
            } else {
                editingMode = .readOnly
                notes.append("RAR archives can be browsed and extracted. To edit them, install RARLAB's command-line tool (brew install --cask rar).")
            }
            if listing.properties["Volumes"].flatMap(Int.init).map({ $0 > 1 }) == true {
                editingMode = .readOnly
                notes.append("Multi-volume RAR archives are read-only.")
            }
        default:
            editingMode = .readOnly
            notes.append("\(format.displayName) files are read-only. You can browse, preview and extract individual items.")
        }
    }

    struct Listing {
        var properties: [String: String] = [:]
        var entries: [ArchiveEntry] = []
        var headersEncrypted = false
    }

    /// Parses `7zz l -slt` ("technical") output.
    static func parseListing(_ text: String) -> Listing {
        var listing = Listing()
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let separator = lines.firstIndex(of: "----------") else { return listing }

        // Archive properties: the last "--" block wins (nested containers).
        for line in lines[..<separator] {
            if line == "--" { listing.properties = [:] }
            if let (key, value) = keyValue(line) { listing.properties[key] = value }
        }
        listing.headersEncrypted = listing.properties["Encrypted"] == "+"

        var block: [String: String] = [:]
        func flush() {
            defer { block = [:] }
            guard let raw = block["Path"] else { return }
            listing.entries.append(entry(from: block, path: raw))
        }
        for line in lines[(separator + 1)...] {
            if line.isEmpty { flush(); continue }
            if let (key, value) = keyValue(line) { block[key] = value }
        }
        flush()
        return listing
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let range = line.range(of: " = ") ?? (line.hasSuffix(" =") ? line.range(of: " =", options: .backwards) : nil)
        else { return nil }
        return (String(line[..<range.lowerBound]), String(line[range.upperBound...]))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func entry(from b: [String: String], path raw: String) -> ArchiveEntry {
        let attributes = b["Attributes"] ?? ""
        // e.g. "D drwxr-xr-x", "A -rw-r--r--", " lrwxrwxrwx"
        let mode = attributes.split(separator: " ").last.map(String.init).flatMap { $0.count == 10 ? $0 : nil }
        let isDir = b["Folder"] == "+" || attributes.hasPrefix("D") || mode?.first == "d"
        let isLink = mode?.first == "l" || b["Symbolic Link"].map { !$0.isEmpty } == true
        var perms: UInt16?
        if let mode {
            var value: UInt16 = 0
            for (i, ch) in mode.dropFirst().enumerated() where ch != "-" { value |= 1 << (8 - i) }
            perms = value
        }
        let modified = b["Modified"].flatMap { s in s.count >= 19 ? dateFormatter.date(from: String(s.prefix(19))) : nil }
        return ArchiveEntry(
            path: ArchivePath.display(raw),
            isDirectory: isDir,
            isSymlink: isLink,
            uncompressedSize: isDir ? 0 : UInt64(b["Size"] ?? "") ?? 0,
            compressedSize: isDir ? 0 : UInt64(b["Packed Size"] ?? ""),
            modificationDate: modified,
            posixPermissions: perms,
            isEncrypted: b["Encrypted"] == "+",
            method: b["Method"].flatMap { $0.isEmpty ? nil : $0 },
            crc32: b["CRC"].flatMap { UInt32($0, radix: 16) },
            linkTarget: b["Symbolic Link"].flatMap { $0.isEmpty ? nil : $0 },
            comment: b["Comment"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    static func format(forType type: String, path: String) -> ArchiveFormat {
        switch type.lowercased() {
        case "7z": return .sevenZip
        case "rar": return .rar
        case "rar5": return .rar5
        case "wim": return .wim
        case "vhd", "vhdx": return .vhd
        case "compound", "msi": return .msi
        case "squashfs": return .squashfs
        case "chm": return .chm
        case "arj": return .arj
        case "udf": return .udf
        case "iso": return .iso9660
        case "dmg", "hfs", "apfs": return .dmg
        case "rpm": return .rpm
        case "cab": return .cab
        case "xar": return .xar
        case "cpio": return .cpio
        case "lzh": return .lha
        case "ar": return .ar
        default: return ArchiveFormat.guess(fromFilename: path) ?? .other
        }
    }

    var statistics: ArchiveStatistics {
        let packed = entries.compactMap(\.compressedSize)
        return ArchiveStatistics(
            fileCount: entries.filter { !$0.isDirectory }.count,
            folderCount: entries.filter(\.isDirectory).count,
            totalUncompressed: entries.reduce(0) { $0 + $1.uncompressedSize },
            totalCompressed: packed.count == entries.count ? packed.reduce(0, +) : nil,
            archiveSize: identity.size,
            reclaimableBytes: 0)
    }

    // MARK: - Errors

    private func check(_ result: ToolRunner.Result, entry: String) throws {
        // 0 = OK, 1 = warnings (e.g. unsupported attributes) — data is fine.
        guard result.status > 1 else { return }
        let message = result.stderr
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("7-Zip") && !$0.hasPrefix("RAR ") }
        let text = message.joined(separator: " ")
        let lower = text.lowercased()
        if lower.contains("wrong password") || lower.contains("incorrect password") || lower.contains("encrypted") && lower.contains("password") {
            throw password == nil ? ArchiveError.passwordRequired(entry: entry) : .wrongPassword(entry: entry)
        }
        if lower.contains("cannot open the file as archive") || lower.contains("can not open the file as archive")
            || lower.contains("is not archive") || lower.contains("is not rar archive") {
            throw ArchiveError.notAnArchive(path)
        }
        if result.status == 255 { throw ArchiveError.cancelled }
        throw ArchiveError.toolFailed(message.last ?? "The archive tool failed (exit code \(result.status)).")
    }

    // MARK: - Extraction

    func extract(where select: (ArchiveEntry) -> Bool, open: (ArchiveEntry) throws -> DataSink?,
                 progress: ProgressReporter?) throws {
        guard try FileIdentity(path: path) == identity else { throw ArchiveError.modifiedExternally }
        let selected = entries.filter(select)
        guard !selected.isEmpty else { return }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("arca-7z-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let files = selected.filter { !$0.isDirectory }
        if !files.isEmpty {
            let list = staging.appendingPathComponent(".arca-list")
            try Data(files.map(\.path).joined(separator: "\n").utf8).write(to: list)
            let out = staging.appendingPathComponent("out")
            progress?.reset(total: 100, phase: "Extracting")
            let result = try ToolRunner.run(tool, ["x", "-y", "-spd", "-snl", "-bso0", "-bsp2", "-sccUTF-8",
                                                   passwordArgument, "-o" + out.path, path, "@" + list.path],
                                            progress: progress)
            try check(result, entry: files.count == 1 ? files[0].path : "")
        }

        let out = staging.appendingPathComponent("out")
        for entry in selected {
            try progress?.checkCancelled()
            guard let sink = try open(entry) else { continue }
            if entry.isDirectory {
                try sink.finish()
                continue
            }
            let file = out.appendingPathComponent(entry.path)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path) {
                try sink.write(Array(target.utf8))
                try sink.finish()
                continue
            }
            let handle = try RandomAccessFile(path: file.path, writable: false)
            try pump(handle, from: 0, length: try handle.size(), into: sink)
            try sink.finish()
        }
    }

    // MARK: - Editing

    private var isRAR: Bool { format == .rar || format == .rar5 }

    func apply(_ changes: [ArchiveChange], options: WriteOptions, progress: ProgressReporter?) throws {
        guard editingMode.isEditable else { throw ArchiveError.readOnly(format: format.displayName) }
        guard try FileIdentity(path: path) == identity else { throw ArchiveError.modifiedExternally }
        guard !changes.isEmpty else { return }

        // Work on a clone; the original is only replaced once everything succeeded.
        let work = temporarySibling(of: path) + "." + (isRAR ? "rar" : "7z")
        try FileManager.default.copyItem(atPath: path, toPath: work)
        defer { unlink(work) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("arca-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let editor = ToolEditor(archive: work, rar: isRAR, sevenZip: tool, password: password, options: options,
                                staging: staging, progress: progress)
        try editor.apply(changes)

        try atomicReplace(path, with: work)
        // With encrypted headers the listing itself now needs the new password.
        if case let .aes256(pw) = options.encryption, !passwords.contains(pw) { passwords.append(pw) }
        identity = try FileIdentity(path: path)
        try scan()
    }

    func compact(progress: ProgressReporter?) throws {}

    // MARK: - Creation

    /// The smallest valid 7z archive (signature header, empty next header).
    static func createEmpty7z(at path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { throw ArchiveError.entryExists(path) }
        var tail = ByteWriter()
        tail.u64(0)
        tail.u64(0)
        tail.u32(0)
        var w = ByteWriter()
        w.append([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04])
        w.u32(CRC32.checksum(tail.bytes))
        w.append(tail.bytes)
        try Data(w.bytes).write(to: URL(fileURLWithPath: path))
    }

    /// RAR can't be created empty: it is built straight from its sources.
    static func createRAR(at path: String, from sources: [URL], options: WriteOptions, progress: ProgressReporter?) throws {
        guard let rar = ExternalTools.rar else { throw ArchiveError.unsupported("creating RAR archives (install RARLAB's rar)") }
        guard !sources.isEmpty else { throw ArchiveError.unsupported("empty RAR archives") }
        let editor = ToolEditor(archive: path, rar: true, sevenZip: rar, password: nil, options: options,
                                staging: FileManager.default.temporaryDirectory.appendingPathComponent("arca-stage-\(UUID().uuidString)"),
                                progress: progress)
        defer { try? FileManager.default.removeItem(at: editor.staging) }
        try editor.apply(sources.map { .add(source: $0, at: $0.lastPathComponent) })
    }
}

/// Translates `ArchiveChange`s into `7zz` / `rar` commands, batching
/// consecutive changes of the same kind into one invocation.
private struct ToolEditor {
    let archive: String
    let rar: Bool
    let sevenZip: URL
    let password: String?
    let options: WriteOptions
    let staging: URL
    let progress: ProgressReporter?

    private enum Kind { case add, delete, rename }

    func apply(_ changes: [ArchiveChange]) throws {
        var batch: [ArchiveChange] = []
        var kind: Kind?
        for change in changes {
            let k = Self.kind(of: change)
            if k != kind, !batch.isEmpty {
                try run(batch, kind!)
                batch = []
            }
            kind = k
            batch.append(change)
        }
        if let kind, !batch.isEmpty { try run(batch, kind) }
    }

    private static func kind(of change: ArchiveChange) -> Kind {
        switch change {
        case .add, .addData, .makeDirectory: .add
        case .delete: .delete
        case .rename: .rename
        }
    }

    private var tool: URL { rar ? (ExternalTools.rar ?? sevenZip) : sevenZip }

    private var writePassword: String? {
        if case let .aes256(pw) = options.encryption { return pw }
        return password
    }

    private func run(_ batch: [ArchiveChange], _ kind: Kind) throws {
        progress?.reset(total: 100, phase: "Updating archive")
        switch kind {
        case .delete:
            let paths = try batch.map { change -> String in
                guard case let .delete(p) = change else { fatalError() }
                return try ArchivePath.normalize(p)
            }
            try invoke(rar ? ["d", "-idq", "-y"] + passwordArgs + ["--", archive] + paths
                           : ["d", "-spd", "-bso0", "-bsp2", "-y"] + passwordArgs + [archive] + paths)
        case .rename:
            let pairs = try batch.flatMap { change -> [String] in
                guard case let .rename(from, to) = change else { fatalError() }
                return [try ArchivePath.normalize(from), try ArchivePath.normalize(to)]
            }
            try invoke(rar ? ["rn", "-idq", "-y"] + passwordArgs + ["--", archive] + pairs
                           : ["rn", "-spd", "-bso0", "-bsp2", "-y"] + passwordArgs + [archive] + pairs)
        case .add:
            let topLevel = try stage(batch)
            guard !topLevel.isEmpty else { return }
            var args: [String]
            let level = max(0, min(9, options.compressionLevel))
            if rar {
                let m = [0, 1, 1, 2, 2, 3, 3, 4, 4, 5][level]
                args = ["a", "-idq", "-y", "-r", "-ol", "-m\(m)"]
                if let pw = writePassword { args.append("-hp" + pw) }
                if options.excludeMacMetadata { args += ["-x*/.DS_Store", "-x.DS_Store", "-x*/__MACOSX", "-x*/._*"] }
                args += ["--", archive] + topLevel
            } else {
                args = ["a", "-y", "-snl", "-bso0", "-bsp2", "-mx=\(level)"]
                if let pw = writePassword { args += ["-p" + pw, "-mhe=on"] }
                if options.excludeMacMetadata { args += ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"] }
                args += [archive] + topLevel
            }
            try invoke(args, in: staging)
            try? FileManager.default.removeItem(at: staging)
        }
    }

    /// Only passed when known: with an empty `-p`, update commands prompt
    /// (and abort, stdin being /dev/null); `rar a -p-` would even set "-" as password.
    private var passwordArgs: [String] { password.map { ["-p" + $0] } ?? [] }

    /// Lays additions out under their archive paths so the tool stores them
    /// there. Files are cloned (APFS) rather than copied.
    private func stage(_ batch: [ArchiveChange]) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var topLevel: [String] = []
        for change in batch {
            let path: String
            switch change {
            case let .add(source, raw):
                path = try ArchivePath.normalize(raw)
                let dest = staging.appendingPathComponent(path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: source, to: dest)
            case let .addData(data, raw):
                path = try ArchivePath.normalize(raw)
                let dest = staging.appendingPathComponent(path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
            case let .makeDirectory(raw):
                path = try ArchivePath.normalize(raw)
                try fm.createDirectory(at: staging.appendingPathComponent(path), withIntermediateDirectories: true)
            default:
                continue
            }
            guard let first = path.split(separator: "/").first.map(String.init) else { continue }
            if !topLevel.contains(first) { topLevel.append(first) }
        }
        return topLevel
    }

    private func invoke(_ args: [String], in directory: URL? = nil) throws {
        let result = try ToolRunner.run(tool, args, in: directory, progress: progress)
        guard result.status > 1 else { return }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("password") { throw password == nil ? ArchiveError.passwordRequired(entry: "") : .wrongPassword(entry: "") }
        if result.status == 255 { throw ArchiveError.cancelled }
        let last = text.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? ""
        throw ArchiveError.toolFailed(last.isEmpty ? "The archive tool failed (exit code \(result.status))." : last)
    }
}
