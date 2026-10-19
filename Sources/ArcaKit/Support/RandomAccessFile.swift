import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thin positional I/O wrapper (pread/pwrite) — no shared file offset, so reads
/// of existing entries and appends of new ones never interfere.
final class RandomAccessFile {
    let path: String
    private let fd: Int32

    init(path: String, writable: Bool, create: Bool = false) throws {
        self.path = path
        var flags = writable ? O_RDWR : O_RDONLY
        if create { flags |= O_CREAT | O_EXCL }
        fd = open(path, flags | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ArchiveError.io(path: path, code: errno) }
    }

    deinit { close(fd) }

    func size() throws -> UInt64 {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ArchiveError.io(path: path, code: errno) }
        return UInt64(st.st_size)
    }

    func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let n = try buffer.withUnsafeMutableBytes { try read(into: $0, at: offset) }
        if n < count { buffer.removeLast(count - n) }
        return buffer
    }

    func readExactly(at offset: UInt64, count: Int) throws -> [UInt8] {
        let bytes = try read(at: offset, count: count)
        guard bytes.count == count else { throw ArchiveError.corrupted("unexpected end of file") }
        return bytes
    }

    /// Fills as much of `buffer` as possible; returns bytes read (short only at EOF).
    @discardableResult
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        var done = 0
        while done < buffer.count {
            let n = pread(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw ArchiveError.io(path: path, code: errno)
            }
            if n == 0 { break }
            done += n
        }
        return done
    }

    func write(_ buffer: UnsafeRawBufferPointer, at offset: UInt64) throws {
        var done = 0
        while done < buffer.count {
            let n = pwrite(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0 {
                if errno == EINTR { continue }
                throw ArchiveError.io(path: path, code: errno)
            }
            done += n
        }
    }

    func write(_ bytes: [UInt8], at offset: UInt64) throws {
        try bytes.withUnsafeBytes { try write($0, at: offset) }
    }

    func truncate(to length: UInt64) throws {
        guard ftruncate(fd, off_t(length)) == 0 else { throw ArchiveError.io(path: path, code: errno) }
    }

    func sync() throws {
        #if canImport(Darwin)
        // fsync on APFS doesn't flush the drive cache; F_FULLFSYNC does.
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        #endif
        guard fsync(fd) == 0 else { throw ArchiveError.io(path: path, code: errno) }
    }
}

struct FileIdentity: Equatable, Sendable {
    let size: UInt64
    let modification: TimeInterval
    let inode: UInt64

    init(path: String) throws {
        var st = stat()
        guard stat(path, &st) == 0 else { throw ArchiveError.io(path: path, code: errno) }
        size = UInt64(st.st_size)
        inode = UInt64(st.st_ino)
        #if canImport(Darwin)
        modification = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
        #else
        modification = TimeInterval(st.st_mtim.tv_sec) + TimeInterval(st.st_mtim.tv_nsec) / 1e9
        #endif
    }
}

/// Atomically replaces `destination` with `source` (same volume), keeping the
/// destination's POSIX permissions.
func atomicReplace(_ destination: String, with source: String) throws {
    var st = stat()
    if stat(destination, &st) == 0 {
        chmod(source, st.st_mode & 0o7777)
    }
    guard rename(source, destination) == 0 else { throw ArchiveError.io(path: destination, code: errno) }
}

func temporarySibling(of path: String) -> String {
    let url = URL(fileURLWithPath: path)
    let name = ".\(url.lastPathComponent).arca-\(UUID().uuidString.prefix(8))"
    return url.deletingLastPathComponent().appendingPathComponent(name).path
}
