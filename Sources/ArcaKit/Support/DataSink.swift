import Foundation
import CZlib
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Push-based byte pipeline stage. Decryptors, codecs and checksums are chained
/// sinks, so a single entry streams from the archive without temp files.
public protocol DataSink: AnyObject {
    func write(_ chunk: UnsafeRawBufferPointer) throws
    func finish() throws
}

extension DataSink {
    func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try write($0) }
    }
}

public final class MemorySink: DataSink {
    public private(set) var data = Data()
    private let limit: Int

    public init(limit: Int = .max) { self.limit = limit }

    public func write(_ chunk: UnsafeRawBufferPointer) throws {
        guard data.count + chunk.count <= limit else {
            throw ArchiveError.unsupported("entry is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))")
        }
        data.append(contentsOf: chunk)
    }

    public func finish() throws {}
}

/// Sequential writer to a new file on disk.
public final class FileSink: DataSink {
    private let fd: Int32
    private let path: String
    private var closed = false

    public init(path: String, permissions: mode_t = 0o644) throws {
        self.path = path
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw ArchiveError.io(path: path, code: errno) }
    }

    deinit { if !closed { close(fd) } }

    public func write(_ chunk: UnsafeRawBufferPointer) throws {
        var done = 0
        while done < chunk.count {
            let n = sysWrite(fd, chunk.baseAddress! + done, chunk.count - done)
            if n < 0 {
                if errno == EINTR { continue }
                throw ArchiveError.io(path: path, code: errno)
            }
            done += n
        }
    }

    public func finish() throws {
        guard !closed else { return }
        closed = true
        guard close(fd) == 0 else { throw ArchiveError.io(path: path, code: errno) }
    }
}

@inline(__always)
private func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buf, count)
    #else
    return Glibc.write(fd, buf, count)
    #endif
}

/// Writes at an explicit offset of a RandomAccessFile and counts bytes.
final class RegionSink: DataSink {
    private let file: RandomAccessFile
    let start: UInt64
    private(set) var count: UInt64 = 0

    init(file: RandomAccessFile, start: UInt64) {
        self.file = file
        self.start = start
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        try file.write(chunk, at: start + count)
        count += UInt64(chunk.count)
    }

    func finish() throws {}
}

final class CRC32Sink: DataSink {
    private let next: DataSink
    private(set) var crc: UInt32 = 0
    private(set) var count: UInt64 = 0

    init(next: DataSink) { self.next = next }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        crc = CRC32.update(crc, chunk)
        count += UInt64(chunk.count)
        try next.write(chunk)
    }

    func finish() throws { try next.finish() }
}

/// Reports bytes flowing through and checks for cancellation.
final class ProgressSink: DataSink {
    private let next: DataSink
    private let progress: ProgressReporter?

    init(next: DataSink, progress: ProgressReporter?) {
        self.next = next
        self.progress = progress
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        if let progress {
            try progress.checkCancelled()
            progress.advance(by: Int64(chunk.count))
        }
        try next.write(chunk)
    }

    func finish() throws { try next.finish() }
}

enum CRC32 {
    static func update(_ crc: UInt32, _ buffer: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return crc }
        var value = uLong(crc)
        var offset = 0
        // zlib's length parameter is 32-bit.
        while offset < buffer.count {
            let n = min(buffer.count - offset, Int(Int32.max))
            value = CZlib.crc32(value, base.advanced(by: offset).assumingMemoryBound(to: Bytef.self), uInt(n))
            offset += n
        }
        return UInt32(truncatingIfNeeded: value)
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { update(0, $0) }
    }
}
