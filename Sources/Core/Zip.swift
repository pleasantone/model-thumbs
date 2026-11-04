import Foundation
#if canImport(Compression)
import Compression
#elseif canImport(CZlib)
import CZlib
#endif

/// Minimal read-only ZIP archive reader (stored + deflate), enough for 3MF/AMF.
public struct ZipArchive {
    public struct Entry {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let data: Data
    public private(set) var entries: [Entry] = []

    public init(_ data: Data) throws {
        self.data = data
        try readCentralDirectory()
    }

    public static func looksLikeZip(_ data: Data) -> Bool {
        data.count > 4 && data.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    private mutating func readCentralDirectory() throws {
        let r = BinaryReader(data)
        // Find End Of Central Directory record (search last 64KB + 22 bytes).
        let minPos = max(0, data.count - 65557)
        var eocd = -1
        var p = data.count - 22
        while p >= minPos {
            if r.peekU32(at: p) == 0x06054b50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw ModelError.malformed("zip: no end of central directory") }

        var total = Int(r.peekU16(at: eocd + 10) ?? 0)
        var cdOffset = Int(r.peekU32(at: eocd + 16) ?? 0)

        // ZIP64: look for the locator right before EOCD.
        if (total == 0xFFFF || cdOffset == 0xFFFFFFFF), eocd >= 20, r.peekU32(at: eocd - 20) == 0x07064b50 {
            var lr = BinaryReader(data)
            lr.offset = eocd - 20 + 8
            if let z64 = lr.u64() {
                let z = Int(z64)
                if r.peekU32(at: z) == 0x06064b50 {
                    var zr = BinaryReader(data)
                    zr.offset = z + 32
                    total = Int(zr.u64() ?? 0)
                    zr.offset = z + 48
                    cdOffset = Int(zr.u64() ?? 0)
                }
            }
        }

        var cr = BinaryReader(data)
        cr.offset = cdOffset
        for _ in 0..<total {
            guard cr.u32() == 0x02014b50 else { break }
            cr.offset += 6 // version made by, version needed, flags
            let method = cr.u16() ?? 0
            cr.offset += 8 // time, date, crc
            var csize = Int(cr.u32() ?? 0)
            var usize = Int(cr.u32() ?? 0)
            let nameLen = Int(cr.u16() ?? 0)
            let extraLen = Int(cr.u16() ?? 0)
            let commentLen = Int(cr.u16() ?? 0)
            cr.offset += 8 // disk start, internal attr, external attr
            var lho = Int(cr.u32() ?? 0)
            guard let nameData = cr.bytes(nameLen) else { break }
            let extraStart = cr.offset
            // ZIP64 extra field
            if csize == 0xFFFFFFFF || usize == 0xFFFFFFFF || lho == 0xFFFFFFFF {
                var er = BinaryReader(data)
                er.offset = extraStart
                while er.offset + 4 <= extraStart + extraLen {
                    let tag = er.u16() ?? 0
                    let len = Int(er.u16() ?? 0)
                    let next = er.offset + len
                    if tag == 0x0001 {
                        if usize == 0xFFFFFFFF { usize = Int(er.u64() ?? 0) }
                        if csize == 0xFFFFFFFF { csize = Int(er.u64() ?? 0) }
                        if lho == 0xFFFFFFFF { lho = Int(er.u64() ?? 0) }
                    }
                    er.offset = next
                }
            }
            cr.offset = extraStart + extraLen + commentLen
            let name = String(decoding: nameData, as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: csize,
                                 uncompressedSize: usize, localHeaderOffset: lho))
        }
    }

    /// Finds an entry by path, ignoring a leading slash and letter case.
    public func entry(named path: String) -> Entry? {
        let want = Self.normalize(path)
        return entries.first { Self.normalize($0.name) == want }
    }

    static func normalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\", with: "/")
        while t.hasPrefix("/") { t.removeFirst() }
        return (t.removingPercentEncoding ?? t).lowercased()
    }

    public func extract(_ entry: Entry) throws -> Data {
        let r = BinaryReader(data)
        let lh = entry.localHeaderOffset
        guard r.peekU32(at: lh) == 0x04034b50,
              let nameLen = r.peekU16(at: lh + 26),
              let extraLen = r.peekU16(at: lh + 28) else {
            throw ModelError.malformed("zip: bad local header for \(entry.name)")
        }
        let start = lh + 30 + Int(nameLen) + Int(extraLen)
        guard start + entry.compressedSize <= data.count else {
            throw ModelError.malformed("zip: truncated entry \(entry.name)")
        }
        let s = data.startIndex + start
        let compressed = data.subdata(in: s..<(s + entry.compressedSize))
        switch entry.method {
        case 0: return compressed
        case 8: return try Self.inflate(compressed, expectedSize: entry.uncompressedSize)
        default: throw ModelError.unsupported("zip compression method \(entry.method)")
        }
    }

    public func extract(named path: String) throws -> Data? {
        guard let e = entry(named: path) else { return nil }
        return try extract(e)
    }

    /// Inflates raw DEFLATE data, stopping after `maxOutput` bytes. Truncated or
    /// trailing-garbage input is tolerated; whatever was decoded is returned.
    public static func inflatePrefix(_ input: Data, maxOutput requested: Int) -> Data {
        let maxOutput = min(requested, maxInflatedSize)
        if input.isEmpty || maxOutput <= 0 { return Data() }
        #if canImport(Compression)
        var out = Data(count: maxOutput)
        let written: Int = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, maxOutput,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        out.count = written
        return out
        #elseif canImport(CZlib)
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
        defer { inflateEnd(&stream) }
        var out = Data(count: maxOutput)
        input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(input.count)
            _ = out.withUnsafeMutableBytes { dst -> Int32 in
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(maxOutput)
                return CZlib.inflate(&stream, Z_FINISH)
            }
        }
        out.count = Int(stream.total_out)
        return out
        #else
        return Data()
        #endif
    }

    /// Upper limit for one decompressed entry, so a crafted archive can't exhaust memory.
    static let maxInflatedSize = 1 << 30

    /// Inflates raw DEFLATE data. `expectedSize` comes from the file, so it isn't trusted:
    /// DEFLATE can't expand by more than about 1032:1, and larger claims are rejected.
    static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        if input.isEmpty { return Data() }
        guard expectedSize >= 0, expectedSize <= min(maxInflatedSize, input.count * 1032 + 1024) else {
            throw ModelError.malformed("zip: declared size is not plausible")
        }
        #if canImport(Compression)
        // COMPRESSION_ZLIB in Apple's Compression framework is raw DEFLATE.
        let capacity = max(expectedSize, 64)
        var out = Data(count: capacity)
        let written: Int = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        if written == 0 { throw ModelError.malformed("zip: inflate failed") }
        out.count = written
        return out
        #elseif canImport(CZlib)
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ModelError.malformed("zip: inflateInit failed")
        }
        defer { inflateEnd(&stream) }
        var out = Data(count: max(expectedSize, 64))
        var status: Int32 = Z_OK
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(input.count)
            repeat {
                if Int(stream.total_out) >= out.count { out.count *= 2 }
                let produced = Int(stream.total_out)
                status = out.withUnsafeMutableBytes { dst -> Int32 in
                    stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress! + produced
                    stream.avail_out = uInt(dst.count - produced)
                    return CZlib.inflate(&stream, Z_NO_FLUSH)
                }
                if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
                    throw ModelError.malformed("zip: inflate error \(status)")
                }
                if status == Z_BUF_ERROR && stream.avail_in == 0 { break }
            } while status != Z_STREAM_END
        }
        out.count = Int(stream.total_out)
        return out
        #else
        throw ModelError.unsupported("no inflate available")
        #endif
    }
}
