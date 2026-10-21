import Foundation
import zlib

public enum GzipError: Error, Equatable, Sendable {
    case notGzip
    case invalid(String)
    case tooLarge(Int)
}

/// gzip through zlib. Inflation is streaming and bounded: it stops with
/// `tooLarge` as soon as the output would pass the limit, so a gzip bomb
/// never gets inflated in full.
public enum Gzip {
    public static func compress(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        var stream = z_stream()
        // 15 window bits + 16: gzip header and trailer.
        var status = deflateInit2_(
            &stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GzipError.invalid("deflateInit2 failed (\(status))") }
        defer { deflateEnd(&stream) }
        var out = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var input = [UInt8](data)
        let inputCount = input.count
        try input.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inputCount)
            repeat {
                try buffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = deflate(&stream, Z_FINISH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw GzipError.invalid("deflate failed (\(status))")
                    }
                    out.append(outPtr.baseAddress!, count: chunk - Int(stream.avail_out))
                }
            } while status != Z_STREAM_END
        }
        return out
    }

    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Inflates [data], throwing `tooLarge` once the output exceeds
    /// [maxBytes] (checked per 64 KiB chunk while inflating).
    public static func decompress(_ data: Data, maxBytes: Int) throws -> Data {
        guard isGzip(data) else { throw GzipError.notGzip }
        var stream = z_stream()
        var status = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GzipError.invalid("inflateInit2 failed (\(status))") }
        defer { inflateEnd(&stream) }
        var out = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var input = [UInt8](data)
        let inputCount = input.count
        try input.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inputCount)
            while true {
                let produced: Int = try buffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = inflate(&stream, Z_NO_FLUSH)
                    switch status {
                    case Z_OK, Z_STREAM_END, Z_BUF_ERROR: break
                    default:
                        let msg = stream.msg.map { String(cString: $0) } ?? "status \(status)"
                        throw GzipError.invalid(msg)
                    }
                    let n = chunk - Int(stream.avail_out)
                    if out.count + n > maxBytes { throw GzipError.tooLarge(maxBytes) }
                    out.append(outPtr.baseAddress!, count: n)
                    return n
                }
                if status == Z_STREAM_END { break }
                if status == Z_BUF_ERROR && produced == 0 {
                    throw GzipError.invalid("truncated gzip data")
                }
                if stream.avail_in == 0 && produced == 0 { throw GzipError.invalid("truncated gzip data") }
            }
        }
        return out
    }
}
