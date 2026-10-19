import Foundation

/// Write-ahead record for in-place ZIP commits.
///
/// A commit only ever overwrites the archive from the start of the old central
/// directory onward. Saving those tail bytes (central directory + EOCD, usually
/// tiny) before touching the file makes every commit recoverable: restoring the
/// tail and truncating yields the original archive byte-for-byte.
public final class JournalStore: Sendable {
    public let directory: URL
    private static let magic = Array("ARCAJ001".utf8)

    public init(directory: URL) {
        self.directory = directory
    }

    public static let shared: JournalStore = {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return JournalStore(directory: base.appendingPathComponent("Arca/Journals", isDirectory: true))
        #else
        return JournalStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("arca-journals"))
        #endif
    }()

    struct Token {
        let url: URL
        let tailOffset: UInt64
        let originalSize: UInt64
        let tail: [UInt8]
    }

    private func journalURL(for archivePath: String) -> URL {
        let canonical = URL(fileURLWithPath: archivePath).resolvingSymlinksInPath().path
        let key = String(format: "%08x", CRC32.checksum(Array(canonical.utf8)))
        let name = URL(fileURLWithPath: canonical).lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "." }
        return directory.appendingPathComponent("\(name.prefix(48))-\(key).journal")
    }

    func begin(archivePath: String, originalSize: UInt64, tailOffset: UInt64, tail: [UInt8]) throws -> Token {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = journalURL(for: archivePath)
        let canonical = Array(URL(fileURLWithPath: archivePath).resolvingSymlinksInPath().path.utf8)
        var w = ByteWriter(capacity: tail.count + canonical.count + 32)
        w.append(Self.magic)
        w.u64(originalSize)
        w.u64(tailOffset)
        w.u32(UInt32(canonical.count))
        w.append(canonical)
        w.append(tail)
        w.u32(CRC32.checksum(w.bytes))

        try? FileManager.default.removeItem(at: url)
        let file = try RandomAccessFile(path: url.path, writable: true, create: true)
        try file.write(w.bytes, at: 0)
        try file.sync()
        return Token(url: url, tailOffset: tailOffset, originalSize: originalSize, tail: tail)
    }

    func end(_ token: Token) {
        try? FileManager.default.removeItem(at: token.url)
    }

    func rollback(_ token: Token, archivePath: String) throws {
        try restore(archivePath: archivePath, tailOffset: token.tailOffset, originalSize: token.originalSize, tail: token.tail)
        end(token)
    }

    /// Restores an archive left half-written by a crash. Returns true if a
    /// recovery happened.
    @discardableResult
    public func recoverIfNeeded(archivePath: String) throws -> Bool {
        let url = journalURL(for: archivePath)
        guard let data = FileManager.default.contents(atPath: url.path) else { return false }
        let bytes = [UInt8](data)
        guard bytes.count >= Self.magic.count + 24, Array(bytes.prefix(8)) == Self.magic,
              CRC32.checksum(Array(bytes.dropLast(4))) == bytes.le32(at: bytes.count - 4) else {
            // Torn journal: the commit never started touching the archive.
            try? FileManager.default.removeItem(at: url)
            return false
        }
        var r = ByteReader(Array(bytes.dropLast(4)), offset: 8)
        let originalSize = try r.u64()
        let tailOffset = try r.u64()
        let pathLength = Int(try r.u32())
        let recordedPath = String(decoding: try r.take(pathLength), as: UTF8.self)
        let tail = try r.take(r.remaining)
        let canonical = URL(fileURLWithPath: archivePath).resolvingSymlinksInPath().path
        guard recordedPath == canonical, UInt64(tail.count) == originalSize - tailOffset else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        try restore(archivePath: archivePath, tailOffset: tailOffset, originalSize: originalSize, tail: tail)
        try? FileManager.default.removeItem(at: url)
        return true
    }

    private func restore(archivePath: String, tailOffset: UInt64, originalSize: UInt64, tail: [UInt8]) throws {
        let file = try RandomAccessFile(path: archivePath, writable: true)
        try file.write(tail, at: tailOffset)
        try file.truncate(to: originalSize)
        try file.sync()
    }
}
