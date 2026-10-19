import Foundation

/// Immutable view of an archive's state, safe to hand to the UI.
public struct ArchiveSnapshot: Sendable {
    public let url: URL
    public let format: ArchiveFormat
    public let editingMode: EditingMode
    public let entries: [ArchiveEntry]
    public let tree: ArchiveTree
    public let statistics: ArchiveStatistics
    public let notes: [String]
    public let isEncrypted: Bool
}

/// Thread-safe handle to an open archive. All work runs on a private serial
/// queue so long I/O never blocks Swift concurrency's cooperative pool.
public final class Archive: @unchecked Sendable {
    public let url: URL
    private let queue: DispatchQueue
    private var backend: ArchiveBackend

    private init(url: URL, backend: ArchiveBackend, queue: DispatchQueue) {
        self.url = url
        self.backend = backend
        self.queue = queue
    }

    // MARK: Opening

    public static func open(_ url: URL, passwords: [String] = [], journal: JournalStore = .shared) async throws -> Archive {
        let queue = DispatchQueue(label: "arca.archive.\(url.lastPathComponent)", qos: .userInitiated)
        return try await run(on: queue) {
            Archive(url: url, backend: try makeBackend(url: url, passwords: passwords, journal: journal), queue: queue)
        }
    }

    static func makeBackend(url: URL, passwords: [String], journal: JournalStore) throws -> ArchiveBackend {
        let path = url.path
        let head = try RandomAccessFile(path: path, writable: false).read(at: 0, count: 4)
        let looksLikeZip = head.count == 4 && head[0] == 0x50 && head[1] == 0x4B &&
            [0x03, 0x05, 0x07].contains(head[2])
        if looksLikeZip || ArchiveFormat.guess(fromFilename: url.lastPathComponent) == .zip {
            do {
                let zip = try ZipArchive(path: path, journal: journal)
                zip.passwords = passwords
                return zip
            } catch let error as ArchiveError where error == .unsupported("multi-volume ZIP archives") {
                throw error
            } catch {
                // Damaged or exotic ZIP: libarchive's streaming reader may still cope (read-only).
                return try LibArchiveBackend(path: path, passwords: passwords, forceReadOnly: true)
            }
        }
        return try LibArchiveBackend(path: path, passwords: passwords)
    }

    /// Creates a new, empty archive.
    public static func create(_ url: URL, format: ArchiveFormat, journal: JournalStore = .shared) async throws -> Archive {
        let queue = DispatchQueue(label: "arca.archive.\(url.lastPathComponent)", qos: .userInitiated)
        return try await run(on: queue) {
            let backend: ArchiveBackend
            if format == .zip {
                backend = try ZipArchive.create(path: url.path, journal: journal)
            } else {
                try LibArchiveBackend.createEmpty(path: url.path, format: format)
                backend = try LibArchiveBackend(path: url.path)
            }
            return Archive(url: url, backend: backend, queue: queue)
        }
    }

    private static func run<T: Sendable>(on queue: DispatchQueue, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (ArchiveBackend) throws -> T) async throws -> T {
        try await Self.run(on: queue) { [self] in try body(self.backend) }
    }

    // MARK: State

    public func snapshot() async throws -> ArchiveSnapshot {
        try await perform { [url] backend in Self.snapshot(of: backend, url: url) }
    }

    private static func snapshot(of backend: ArchiveBackend, url: URL) -> ArchiveSnapshot {
        ArchiveSnapshot(url: url, format: backend.format, editingMode: backend.editingMode, entries: backend.entries,
                        tree: ArchiveTree(entries: backend.entries), statistics: backend.statistics,
                        notes: backend.notes, isEncrypted: backend.isEncrypted)
    }

    public func addPassword(_ password: String) async throws {
        _ = try await perform { backend in
            if !backend.passwords.contains(password) { backend.passwords.append(password) }
        }
    }

    /// Re-reads the archive from disk (e.g. after an external change).
    public func reload() async throws -> ArchiveSnapshot {
        try await Self.run(on: queue) { [self] in
            let passwords = backend.passwords
            backend = try Self.makeBackend(url: url, passwords: passwords, journal: .shared)
            return Self.snapshot(of: backend, url: url)
        }
    }

    // MARK: Reading

    /// Extracts `paths` (files or folders; empty = everything) into
    /// `destination`, stripping the `base` prefix. Returns the top-level URLs.
    @discardableResult
    public func extract(_ paths: [String], relativeTo base: String = "", to destination: URL,
                        conflict: ConflictPolicy = .keepBoth, progress: ProgressReporter? = nil) async throws -> [URL] {
        try await perform { backend in
            try Extractor(backend: backend, destination: destination, base: base, conflict: conflict)
                .run(paths: paths, progress: progress)
        }
    }

    /// Extracts one entry into a fresh private folder, for previews and editing.
    public func extractForEditing(_ path: String, in root: URL) async throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try await extract([path], relativeTo: ArchivePath.parent(path), to: folder, conflict: .overwrite)
        guard let url = urls.first else { throw ArchiveError.entryNotFound(path) }
        return url
    }

    public func data(for path: String, limit: Int = 64 << 20) async throws -> Data {
        try await perform { backend in
            let sink = MemorySink(limit: limit)
            var found = false
            try backend.extract(where: { $0.path == path && !$0.isDirectory }, open: { _ in
                found = true
                return sink
            }, progress: nil)
            guard found else { throw ArchiveError.entryNotFound(path) }
            return sink.data
        }
    }

    // MARK: Writing

    public func apply(_ changes: [ArchiveChange], options: WriteOptions = .default,
                      progress: ProgressReporter? = nil) async throws -> ArchiveSnapshot {
        try await perform { [url] backend in
            try backend.apply(changes, options: options, progress: progress)
            return Self.snapshot(of: backend, url: url)
        }
    }

    public func compact(progress: ProgressReporter? = nil) async throws -> ArchiveSnapshot {
        try await perform { [url] backend in
            try backend.compact(progress: progress)
            return Self.snapshot(of: backend, url: url)
        }
    }
}

extension Archive {
    /// One-shot creation from files on disk (Finder service, drag to dock).
    public static func compress(_ sources: [URL], into url: URL, format: ArchiveFormat,
                                options: WriteOptions = .default, progress: ProgressReporter? = nil) async throws -> Archive {
        let archive = try await create(url, format: format)
        let changes = sources.map { ArchiveChange.add(source: $0, at: $0.lastPathComponent) }
        _ = try await archive.apply(changes, options: options, progress: progress)
        return archive
    }
}
