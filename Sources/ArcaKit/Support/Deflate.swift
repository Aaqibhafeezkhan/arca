import CZlib

private let zBufferSize = 256 * 1024

/// Raw (headerless) DEFLATE decoder, as used by ZIP method 8.
final class InflateSink: DataSink {
    private let next: DataSink
    // z_stream holds a back-pointer checked by zlib, so it must not move.
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    private let out = UnsafeMutablePointer<UInt8>.allocate(capacity: zBufferSize)
    private var ended = false

    init(next: DataSink) throws {
        self.next = next
        stream.initialize(to: z_stream())
        guard inflateInit2_(stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deallocate()
            out.deallocate()
            throw ArchiveError.unsupported("zlib initialisation failed")
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
        out.deallocate()
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        guard chunk.count > 0, !ended else { return }
        stream.pointee.next_in = UnsafeMutablePointer(mutating: chunk.baseAddress!.assumingMemoryBound(to: Bytef.self))
        stream.pointee.avail_in = uInt(chunk.count)
        try pump(flush: Z_NO_FLUSH)
    }

    func finish() throws {
        if !ended {
            stream.pointee.next_in = nil
            stream.pointee.avail_in = 0
            try pump(flush: Z_FINISH)
        }
        guard ended else { throw ArchiveError.corrupted("unexpected end of deflate stream") }
        try next.finish()
    }

    private func pump(flush: Int32) throws {
        repeat {
            stream.pointee.next_out = out
            stream.pointee.avail_out = uInt(zBufferSize)
            let status = inflate(stream, flush)
            let produced = zBufferSize - Int(stream.pointee.avail_out)
            if produced > 0 { try next.write(UnsafeRawBufferPointer(start: out, count: produced)) }
            switch status {
            case Z_STREAM_END:
                ended = true
                return
            case Z_OK:
                continue
            case Z_BUF_ERROR:
                // No progress possible: needs more input (or input ended early).
                return
            default:
                throw ArchiveError.corrupted("invalid deflate data")
            }
        } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0
    }
}

final class DeflateSink: DataSink {
    private let next: DataSink
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    private let out = UnsafeMutablePointer<UInt8>.allocate(capacity: zBufferSize)

    init(next: DataSink, level: Int) throws {
        self.next = next
        stream.initialize(to: z_stream())
        let status = deflateInit2_(stream, Int32(max(1, min(9, level))), Z_DEFLATED, -MAX_WBITS, 8,
                                   Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            stream.deallocate()
            out.deallocate()
            throw ArchiveError.unsupported("zlib initialisation failed")
        }
    }

    deinit {
        deflateEnd(stream)
        stream.deallocate()
        out.deallocate()
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        guard chunk.count > 0 else { return }
        stream.pointee.next_in = UnsafeMutablePointer(mutating: chunk.baseAddress!.assumingMemoryBound(to: Bytef.self))
        stream.pointee.avail_in = uInt(chunk.count)
        repeat {
            try drain(flush: Z_NO_FLUSH)
        } while stream.pointee.avail_in > 0
    }

    func finish() throws {
        stream.pointee.next_in = nil
        stream.pointee.avail_in = 0
        while try drain(flush: Z_FINISH) != Z_STREAM_END {}
        try next.finish()
    }

    @discardableResult
    private func drain(flush: Int32) throws -> Int32 {
        stream.pointee.next_out = out
        stream.pointee.avail_out = uInt(zBufferSize)
        let status = deflate(stream, flush)
        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
            throw ArchiveError.corrupted("deflate failed (\(status))")
        }
        let produced = zBufferSize - Int(stream.pointee.avail_out)
        if produced > 0 { try next.write(UnsafeRawBufferPointer(start: out, count: produced)) }
        return status
    }
}
