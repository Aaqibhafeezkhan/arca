import Foundation

protocol ArchiveBackend: AnyObject {
    var format: ArchiveFormat { get }
    var editingMode: EditingMode { get }
    /// Unique by path, in archive order.
    var entries: [ArchiveEntry] { get }
    var passwords: [String] { get set }
    var notes: [String] { get }
    var statistics: ArchiveStatistics { get }
    var isEncrypted: Bool { get }

    /// Streams every entry accepted by `select` into the sink returned by
    /// `open` (nil skips it). One pass over the archive for stream formats.
    func extract(where select: (ArchiveEntry) -> Bool,
                 open: (ArchiveEntry) throws -> DataSink?,
                 progress: ProgressReporter?) throws

    func apply(_ changes: [ArchiveChange], options: WriteOptions, progress: ProgressReporter?) throws
    func compact(progress: ProgressReporter?) throws
}

/// Pumps a byte range of a file into a sink.
func pump(_ file: RandomAccessFile, from offset: UInt64, length: UInt64, into sink: DataSink) throws {
    let chunk = 1 << 20
    var buffer = [UInt8](repeating: 0, count: chunk)
    var done: UInt64 = 0
    while done < length {
        let n = Int(min(UInt64(chunk), length - done))
        let read = try buffer.withUnsafeMutableBytes {
            try file.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<n]), at: offset + done)
        }
        guard read == n else { throw ArchiveError.corrupted("unexpected end of file") }
        try buffer.withUnsafeBytes { try sink.write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        done += UInt64(n)
    }
}

/// Feeds an addition's content into a sink.
func feed(_ source: AdditionSource, into sink: DataSink) throws {
    switch source {
    case let .file(url, _):
        let file = try RandomAccessFile(path: url.path, writable: false)
        let size = try file.size()
        try pump(file, from: 0, length: size, into: sink)
    case let .data(data):
        try data.withUnsafeBytes { try sink.write($0) }
    case let .symlink(target):
        try sink.write(Array(target.utf8))
    case .directory:
        break
    }
    try sink.finish()
}
