import CryptoKit
import Darwin
import Foundation
import zlib

enum ResourceIO {
    static let chunkSize = 65536
    static func checkDeadline(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ResourceStoreError.timedOut }
    }
    static func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 30_000_000_000 }

    static func read(_ file: Int32, buffer: inout [UInt8], offset: Int, count: Int) throws -> Int {
        while true {
            let size = pread(file, &buffer, count, off_t(offset))
            if size < 0, errno == EINTR { continue }
            guard size >= 0 else { throw ResourceStoreError.io }
            return size
        }
    }
    static func write(_ file: Int32, bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let size = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if size < 0, errno == EINTR { continue }
            guard size > 0 else { throw ResourceStoreError.io }
            offset += size
        }
    }

    @discardableResult
    static func scan(_ source: Int32, destination: Int32? = nil, limit: Int, expected: String,
                     size: Int? = nil, deadline: UInt64) throws -> Int {
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw ResourceStoreError.invalidSource
        }
        guard info.st_size <= limit else { throw ResourceStoreError.tooLarge }
        var offset = 0
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try checkDeadline(deadline)
            let count = try read(source, buffer: &buffer, offset: offset, count: min(chunkSize, limit + 1 - offset))
            if count == 0 { break }
            offset += count
            guard offset <= limit else { throw ResourceStoreError.tooLarge }
            try buffer.withUnsafeBytes { raw in
                let bytes = UnsafeRawBufferPointer(rebasing: raw[..<count])
                digest.update(bufferPointer: bytes)
                if let destination { try write(destination, bytes: bytes) }
            }
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == expected, size == nil || size == offset else { throw ResourceStoreError.integrity }
        return offset
    }

    /// Decode exactly one gzip member, check its CRC/trailer, and reject extra
    /// bytes. The compressed source is already a verified private copy.
    static func inflateGzip(_ source: Int32, into destination: Int32, limit: Int, deadline: UInt64) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ResourceStoreError.invalidArchive
        }
        defer { inflateEnd(&stream) }
        var input = [UInt8](repeating: 0, count: chunkSize)
        var output = [UInt8](repeating: 0, count: chunkSize)
        var offset = 0
        var total = 0
        while true {
            try checkDeadline(deadline)
            let count = try read(source, buffer: &input, offset: offset, count: chunkSize)
            guard count > 0 else { throw ResourceStoreError.invalidArchive }
            offset += count
            let ended = try input.withUnsafeMutableBytes { inputBytes -> Bool in
                stream.next_in = inputBytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.avail_in = uInt(count)
                while true {
                    try checkDeadline(deadline)
                    let before = stream.avail_in
                    let (result, produced) = output.withUnsafeMutableBytes { outputBytes -> (Int32, Int) in
                        stream.next_out = outputBytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
                        stream.avail_out = uInt(chunkSize)
                        let status = inflate(&stream, Z_NO_FLUSH)
                        return (status, chunkSize - Int(stream.avail_out))
                    }
                    total += produced
                    guard total <= limit else { throw ResourceStoreError.tooLarge }
                    try output.withUnsafeBytes { try write(destination, bytes: .init(rebasing: $0[..<produced])) }
                    if result == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw ResourceStoreError.invalidArchive }
                        return true
                    }
                    guard result == Z_OK || (result == Z_BUF_ERROR && stream.avail_in == 0) else {
                        throw ResourceStoreError.invalidArchive
                    }
                    if stream.avail_in == 0 && produced < chunkSize { return false }
                    guard stream.avail_in < before || produced > 0 else { throw ResourceStoreError.invalidArchive }
                }
            }
            if ended {
                guard try read(source, buffer: &input, offset: offset, count: 1) == 0 else {
                    throw ResourceStoreError.invalidArchive
                }
                return
            }
        }
    }

    static func verifyMachO(_ file: Int32, architecture: String) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard try read(file, buffer: &bytes, offset: 0, count: 32) == 32 else { throw ResourceStoreError.integrity }
        func word(_ start: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[start + $1]) << ($1 * 8) }
        }
        let cpu: UInt32 = architecture == "arm64" ? 0x0100000c : 0x01000007
        guard word(0) == 0xfeedfacf, word(4) == cpu, word(12) == 2 else { throw ResourceStoreError.integrity }
    }
}
