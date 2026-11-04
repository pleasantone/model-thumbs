import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A byte buffer that is always followed by a NUL terminator, so C number
/// parsers (strtod / strtol) can run directly on it without copying.
public final class TextBuffer {
    public let storage: UnsafeMutablePointer<UInt8>
    public let count: Int

    public init(_ data: Data) {
        count = data.count
        storage = UnsafeMutablePointer<UInt8>.allocate(capacity: count + 1)
        data.copyBytes(to: storage, count: count)
        storage[count] = 0
    }

    public init(bytes: [UInt8]) {
        count = bytes.count
        storage = UnsafeMutablePointer<UInt8>.allocate(capacity: count + 1)
        bytes.withUnsafeBufferPointer { b in
            if let base = b.baseAddress { storage.update(from: base, count: count) }
        }
        storage[count] = 0
    }

    deinit { storage.deallocate() }

    /// Reads outside the buffer return 0 (the same as the terminator).
    @inline(__always) public subscript(i: Int) -> UInt8 { i >= 0 && i < count ? storage[i] : 0 }

    /// Parses a floating point number at `pos`. Returns nil if nothing parsed.
    @inline(__always)
    public func parseDouble(at pos: Int, end: inout Int) -> Double? {
        guard pos >= 0, pos < count else { end = pos; return nil }
        let start = UnsafeMutableRawPointer(storage + pos).assumingMemoryBound(to: CChar.self)
        var endPtr: UnsafeMutablePointer<CChar>? = nil
        let v = strtod(start, &endPtr)
        guard let e = endPtr, e != start else { end = pos; return nil }
        end = pos + (UnsafeMutableRawPointer(e) - UnsafeMutableRawPointer(start))
        return v
    }

    @inline(__always)
    public func parseInt(at pos: Int, end: inout Int) -> Int? {
        guard pos >= 0, pos < count else { end = pos; return nil }
        let start = UnsafeMutableRawPointer(storage + pos).assumingMemoryBound(to: CChar.self)
        var endPtr: UnsafeMutablePointer<CChar>? = nil
        let v = strtol(start, &endPtr, 10)
        guard let e = endPtr, e != start else { end = pos; return nil }
        end = pos + (UnsafeMutableRawPointer(e) - UnsafeMutableRawPointer(start))
        return v
    }

    @inline(__always)
    public func skipSpaces(_ pos: inout Int) {
        while pos < count {
            let c = storage[pos]
            if c == 32 || c == 9 || c == 13 { pos += 1 } else { break }
        }
    }

    @inline(__always)
    public func skipToNextLine(_ pos: inout Int) {
        while pos < count && storage[pos] != 10 { pos += 1 }
        if pos < count { pos += 1 }
    }

    /// Compares bytes at `pos` against an ASCII literal.
    @inline(__always)
    public func matches(_ literal: StaticString, at pos: Int) -> Bool {
        let n = literal.utf8CodeUnitCount
        if pos + n > count { return false }
        let lp = literal.utf8Start
        for i in 0..<n where storage[pos + i] != lp[i] { return false }
        return true
    }

    public func string(_ start: Int, _ end: Int) -> String {
        let s = max(0, start), e = min(end, count)
        guard e > s else { return "" }
        return String(decoding: UnsafeBufferPointer(start: storage + s, count: e - s), as: UTF8.self)
    }
}

/// Little/big-endian binary reader over Data.
public struct BinaryReader {
    public let data: Data
    public var offset: Int = 0
    public var bigEndian = false

    public init(_ data: Data, bigEndian: Bool = false) {
        self.data = data
        self.bigEndian = bigEndian
    }

    public var remaining: Int { data.count - offset }

    @inline(__always)
    private func raw<T: FixedWidthInteger>(_ type: T.Type, at pos: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard pos >= 0, pos + size <= data.count else { return nil }
        var v: T = 0
        data.withUnsafeBytes { buf in
            v = buf.loadUnaligned(fromByteOffset: pos, as: T.self)
        }
        return bigEndian ? T(bigEndian: v) : T(littleEndian: v)
    }

    public func peekU32(at pos: Int) -> UInt32? { raw(UInt32.self, at: pos) }
    public func peekU16(at pos: Int) -> UInt16? { raw(UInt16.self, at: pos) }

    public mutating func u8() -> UInt8? {
        guard offset < data.count else { return nil }
        let v = data[data.startIndex + offset]; offset += 1; return v
    }
    public mutating func u16() -> UInt16? { let v = raw(UInt16.self, at: offset); if v != nil { offset += 2 }; return v }
    public mutating func u32() -> UInt32? { let v = raw(UInt32.self, at: offset); if v != nil { offset += 4 }; return v }
    public mutating func u64() -> UInt64? { let v = raw(UInt64.self, at: offset); if v != nil { offset += 8 }; return v }
    public mutating func i8() -> Int8? { u8().map { Int8(bitPattern: $0) } }
    public mutating func i16() -> Int16? { u16().map { Int16(bitPattern: $0) } }
    public mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
    public mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
    public mutating func f64() -> Double? { u64().map { Double(bitPattern: $0) } }

    public mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, offset + n <= data.count else { return nil }
        let s = data.startIndex + offset
        offset += n
        return data.subdata(in: s..<(s + n))
    }
}

extension Data {
    /// Reads a file fully, memory-mapped when possible.
    static func readModelFile(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.alwaysMapped])
    }

    var isPNG: Bool { count > 8 && self.starts(with: [0x89, 0x50, 0x4E, 0x47]) }
    var isJPEG: Bool { count > 3 && self.starts(with: [0xFF, 0xD8, 0xFF]) }
}
