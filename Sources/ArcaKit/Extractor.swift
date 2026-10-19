import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Materialises entries on disk. Guards against path traversal ("zip slip")
/// and symlinks pointing outside the destination.
struct Extractor {
    let backend: ArchiveBackend
    let destination: URL
    let base: String
    let conflict: ConflictPolicy
    private let fm = FileManager.default

    init(backend: ArchiveBackend, destination: URL, base: String, conflict: ConflictPolicy) {
        self.backend = backend
        self.destination = destination.standardizedFileURL
        self.base = base
        self.conflict = conflict
    }

    func run(paths: [String], progress: ProgressReporter?) throws -> [URL] {
        let roots = paths.isEmpty ? [""] : paths
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Top-level names are renamed up-front for keepBoth so a whole folder
        // lands next to an existing one instead of merging into it.
        var topLevelRename: [String: String] = [:]
        var topLevel: [String] = []
        for entry in backend.entries where matches(entry.path, roots) {
            guard let first = relative(entry.path)?.split(separator: "/").first.map(String.init),
                  !topLevel.contains(first) else { continue }
            topLevel.append(first)
            if conflict == .keepBoth, fm.fileExists(atPath: destination.appendingPathComponent(first).path) {
                topLevelRename[first] = uniqueName(for: first)
            }
        }

        var directoryDates: [(URL, Date)] = []
        var extractedTargets: [String: URL] = [:]

        try backend.extract(where: { matches($0.path, roots) }, open: { entry in
            guard let rel = relative(entry.path) else { return nil }
            var components = try ArchivePath.safeComponents(rel)
            guard !components.isEmpty else { return nil }
            if let renamed = topLevelRename[components[0]] { components[0] = renamed }
            let target = components.reduce(destination) { $0.appendingPathComponent($1) }

            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                if let date = entry.modificationDate { directoryDates.append((target, date)) }
                return nil
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                switch conflict {
                case .skip: return nil
                case .overwrite, .keepBoth: try fm.removeItem(at: target)
                }
            }

            if entry.isSymlink {
                if let linkTarget = entry.linkTarget {
                    try makeSymlink(at: target, pointingTo: linkTarget)
                    return nil
                }
                return SymlinkSink(at: target, extractor: self)
            }
            if let hard = entry.hardLinkTarget, let source = extractedTargets[hard] {
                try fm.copyItem(at: source, to: target)
                return nil
            }
            extractedTargets[entry.path] = target
            let mode = mode_t(entry.posixPermissions.map { $0 & 0o777 } ?? 0o644)
            return FinalizingSink(next: try FileSink(path: target.path, permissions: mode | 0o200)) {
                if let date = entry.modificationDate {
                    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
                }
                if let perms = entry.posixPermissions {
                    try? fm.setAttributes([.posixPermissions: NSNumber(value: perms & 0o777)], ofItemAtPath: target.path)
                }
            }
        }, progress: progress)

        for (url, date) in directoryDates.reversed() {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return topLevel.map { destination.appendingPathComponent(topLevelRename[$0] ?? $0) }
            .filter { fm.fileExists(atPath: $0.path) || (try? fm.destinationOfSymbolicLink(atPath: $0.path)) != nil }
    }

    private func matches(_ path: String, _ roots: [String]) -> Bool {
        roots.contains { $0.isEmpty || path == $0 || ArchivePath.isDescendant(path, of: $0) }
    }

    private func relative(_ path: String) -> String? {
        if base.isEmpty { return path }
        guard ArchivePath.isDescendant(path, of: base) else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    private func uniqueName(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !fm.fileExists(atPath: destination.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }

    fileprivate func makeSymlink(at target: URL, pointingTo linkTarget: String) throws {
        // Only relative links that stay inside the destination are recreated.
        guard !linkTarget.hasPrefix("/") else { return }
        let resolved = target.deletingLastPathComponent().appendingPathComponent(linkTarget).standardizedFileURL.path
        guard resolved == destination.path || resolved.hasPrefix(destination.path + "/") else { return }
        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
    }
}

private final class FinalizingSink: DataSink {
    private let next: DataSink
    private let completion: () throws -> Void

    init(next: DataSink, completion: @escaping () throws -> Void) {
        self.next = next
        self.completion = completion
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws { try next.write(chunk) }

    func finish() throws {
        try next.finish()
        try completion()
    }
}

/// ZIP stores symlink targets as entry data.
private final class SymlinkSink: DataSink {
    private let target: URL
    private let extractor: Extractor
    private var bytes: [UInt8] = []

    init(at target: URL, extractor: Extractor) {
        self.target = target
        self.extractor = extractor
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        guard bytes.count + chunk.count <= 4096 else { throw ArchiveError.corrupted("symlink target too long") }
        bytes.append(contentsOf: chunk)
    }

    func finish() throws {
        try extractor.makeSymlink(at: target, pointingTo: String(decoding: bytes, as: UTF8.self))
    }
}
