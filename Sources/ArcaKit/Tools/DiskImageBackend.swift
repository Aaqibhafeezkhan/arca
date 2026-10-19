import Foundation

/// Presents one or more directory trees (mounted volumes) as a read-only archive.
class FolderBackend: ArchiveBackend {
    let roots: [(name: String, url: URL)]
    let format: ArchiveFormat
    let editingMode: EditingMode = .readOnly
    private(set) var entries: [ArchiveEntry] = []
    private(set) var notes: [String] = []
    var isEncrypted = false
    var passwords: [String] = []
    private var locations: [String: URL] = [:]
    private let size: UInt64

    /// With a single root its contents appear at the top level; with several,
    /// each root becomes a top-level folder.
    init(roots: [(name: String, url: URL)], format: ArchiveFormat, archiveSize: UInt64, notes: [String] = []) {
        self.roots = roots
        self.format = format
        self.size = archiveSize
        self.notes = notes
        scan()
    }

    private func scan() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey]
        let hidden: Set<String> = [".Trashes", ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100",
                                   ".TemporaryItems", ".HFS+ Private Directory Data\r", ".journal", ".journal_info_block"]
        var result: [ArchiveEntry] = []
        for root in roots {
            let prefix = roots.count == 1 ? "" : root.name
            if !prefix.isEmpty {
                result.append(ArchiveEntry(path: prefix, isDirectory: true, uncompressedSize: 0))
                locations[prefix] = root.url
            }
            let base = root.url.standardizedFileURL.pathComponents.count
            guard let e = fm.enumerator(at: root.url, includingPropertiesForKeys: keys, options: []) else { continue }
            for case let url as URL in e {
                if hidden.contains(url.lastPathComponent) {
                    e.skipDescendants()
                    continue
                }
                let rel = url.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
                guard !rel.isEmpty else { continue }
                let path = ArchivePath.join(prefix, rel)
                let v = try? url.resourceValues(forKeys: Set(keys))
                let isLink = v?.isSymbolicLink == true
                let isDir = v?.isDirectory == true && !isLink
                let perms = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value
                result.append(ArchiveEntry(
                    path: path, isDirectory: isDir, isSymlink: isLink,
                    uncompressedSize: isDir ? 0 : UInt64(v?.fileSize ?? 0),
                    compressedSize: nil, modificationDate: v?.contentModificationDate,
                    posixPermissions: perms.map { $0 & 0o7777 },
                    linkTarget: isLink ? try? fm.destinationOfSymbolicLink(atPath: url.path) : nil))
                locations[path] = url
            }
        }
        entries = result
    }

    var statistics: ArchiveStatistics {
        ArchiveStatistics(fileCount: entries.filter { !$0.isDirectory }.count,
                          folderCount: entries.filter(\.isDirectory).count,
                          totalUncompressed: entries.reduce(0) { $0 + $1.uncompressedSize },
                          totalCompressed: nil, archiveSize: size, reclaimableBytes: 0)
    }

    func extract(where select: (ArchiveEntry) -> Bool, open: (ArchiveEntry) throws -> DataSink?,
                 progress: ProgressReporter?) throws {
        let selected = entries.filter(select)
        progress?.reset(total: Int64(selected.reduce(0) { $0 + $1.uncompressedSize }), phase: "Extracting")
        for entry in selected {
            try progress?.checkCancelled()
            guard let sink = try open(entry) else { continue }
            if entry.isDirectory {
                try sink.finish()
            } else if entry.isSymlink {
                try sink.write(Array((entry.linkTarget ?? "").utf8))
                try sink.finish()
            } else if let url = locations[entry.path] {
                let file = try RandomAccessFile(path: url.path, writable: false)
                try pump(file, from: 0, length: try file.size(), into: ProgressSink(next: sink, progress: progress))
                try sink.finish()
            }
        }
    }

    func apply(_ changes: [ArchiveChange], options: WriteOptions, progress: ProgressReporter?) throws {
        throw ArchiveError.readOnly(format: format.displayName)
    }

    func compact(progress: ProgressReporter?) throws {}
}

#if os(macOS)
/// DMG via `hdiutil`: mounted read-only, hidden from Finder, detached when closed.
/// Native support covers APFS/HFS+, compressed and encrypted images.
final class DiskImageBackend: FolderBackend {
    private let mountPoints: [URL]

    init(path: String, passwords: [String]) throws {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let check = try ToolRunner.run(hdiutil, ["isencrypted", "-plist", path])
        let encrypted = (try? PropertyListSerialization.propertyList(from: check.stdout, format: nil) as? [String: Any])?["encrypted"] as? Bool ?? false
        if encrypted && passwords.isEmpty { throw ArchiveError.passwordRequired(entry: "") }

        var args = ["attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", "-noverify",
                    "-mountrandom", FileManager.default.temporaryDirectory.path]
        if encrypted { args.append("-stdinpass") }
        args.append(path)
        let result = try DiskImageBackend.attach(hdiutil, args, password: encrypted ? passwords.last : nil)
        guard result.status == 0 else {
            if encrypted { throw ArchiveError.wrongPassword(entry: "") }
            throw ArchiveError.toolFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let plist = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        mountPoints = entities.compactMap { $0["mount-point"] as? String }.map { URL(fileURLWithPath: $0) }
        guard !mountPoints.isEmpty else { throw ArchiveError.unsupported("this disk image has no readable volume") }

        let size = (try? FileIdentity(path: path).size) ?? 0
        super.init(roots: mountPoints.map { ($0.lastPathComponent, $0) }, format: .dmg, archiveSize: size,
                   notes: ["Disk images are mounted read-only and invisibly while open. Items can be previewed and extracted."])
        isEncrypted = encrypted
        self.passwords = passwords
    }

    /// `hdiutil -stdinpass` reads the password from standard input.
    private static func attach(_ tool: URL, _ args: [String], password: String?) throws -> ToolRunner.Result {
        guard let password else { return try ToolRunner.run(tool, args) }
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(password.utf8) + Data([0]))  // -stdinpass expects NUL-terminated
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolRunner.Result(status: process.terminationStatus, stdout: out, stderr: String(decoding: err, as: UTF8.self))
    }

    deinit {
        for mount in mountPoints {
            _ = try? ToolRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", "-force", mount.path])
        }
    }
}
#endif
