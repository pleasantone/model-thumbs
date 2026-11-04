import Foundation

/// Helpers for preview images stored in raw or legacy pixel formats.
/// Everything is converted to PNG bytes so the rest of the pipeline only
/// deals with PNG/JPEG.
public enum ImageDecode {

    /// Builds an opaque image from a pixel callback returning (r, g, b).
    static func makeImage(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Image {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let o = (y * width + x) * 4
                px[o] = r; px[o + 1] = g; px[o + 2] = b
            }
        }
        return Image(width: width, height: height, pixels: px)
    }

    public static func png(_ img: Image) -> Data { PNGWriter.encode(img) }

    // MARK: RGB565

    /// 16-bit 5-6-5 pixels, row-major top-down.
    public static func rgb565(_ data: Data, offset: Int, width: Int, height: Int, bigEndian: Bool) -> Image? {
        guard width > 0, height > 0, offset >= 0, offset + width * height * 2 <= data.count else { return nil }
        return data.withUnsafeBytes { raw -> Image in
            makeImage(width: width, height: height) { x, y in
                let o = offset + (y * width + x) * 2
                let a = UInt16(raw[o]), b = UInt16(raw[o + 1])
                let v = bigEndian ? (a << 8 | b) : (b << 8 | a)
                return (UInt8((v >> 11) & 0x1F) << 3, UInt8((v >> 5) & 0x3F) << 2, UInt8(v & 0x1F) << 3)
            }
        }
    }

    // MARK: Chitubox RGB15 RLE

    /// Chitubox-family preview encoding: 16-bit RGB15 with a repeat flag (0x20).
    public static func chituRLE(_ data: Data, offset: Int, length: Int, width: Int, height: Int) -> Image? {
        guard width > 0, height > 0, offset >= 0, length > 0, offset + length <= data.count else { return nil }
        var px = [UInt8](repeating: 255, count: width * height * 4)
        let total = width * height
        var pixel = 0
        let ok: Bool = data.withUnsafeBytes { raw -> Bool in
            var i = offset
            let end = offset + length
            while i + 1 < end {
                let dot = UInt16(raw[i]) | UInt16(raw[i + 1]) << 8
                i += 2
                var repeatCount = 1
                if dot & 0x20 != 0 {
                    guard i + 1 < end else { return false }
                    repeatCount += Int(raw[i]) | (Int(raw[i + 1] & 0x0F) << 8)
                    i += 2
                }
                let r = UInt8((dot >> 11) & 0x1F) << 3
                let g = UInt8((dot >> 6) & 0x1F) << 3
                let b = UInt8(dot & 0x1F) << 3
                guard pixel + repeatCount <= total else { return false }
                for _ in 0..<repeatCount {
                    let o = pixel * 4
                    px[o] = r; px[o + 1] = g; px[o + 2] = b
                    pixel += 1
                }
            }
            return true
        }
        // Accept slightly short data (encoders sometimes stop early), reject garbage.
        guard ok, pixel >= total * 3 / 4 else { return nil }
        return Image(width: width, height: height, pixels: px)
    }

    // MARK: QOI

    /// Decodes a QOI image (https://qoiformat.org). Returns nil for anything malformed or truncated.
    public static func qoi(_ data: Data) -> Image? {
        let bytes = [UInt8](data)
        guard bytes.count > 14, bytes[0] == 0x71, bytes[1] == 0x6F, bytes[2] == 0x69, bytes[3] == 0x66 else { return nil }
        func be32(_ p: Int) -> Int {
            Int(bytes[p]) << 24 | Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
        }
        let width = be32(4), height = be32(8)
        // A run opcode covers at most 62 pixels per byte, which bounds what a real file can claim.
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= (bytes.count - 14) * 62 else { return nil }
        let total = width * height
        var out = [UInt8](repeating: 0, count: total * 4)
        var seen = [UInt8](repeating: 0, count: 64 * 4)
        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 255
        var p = 14, pixel = 0, run = 0
        while pixel < total {
            if run > 0 {
                run -= 1
            } else {
                guard p < bytes.count else { return nil }
                let op = bytes[p]; p += 1
                if op == 0xFE {
                    guard p + 3 <= bytes.count else { return nil }
                    r = bytes[p]; g = bytes[p + 1]; b = bytes[p + 2]; p += 3
                } else if op == 0xFF {
                    guard p + 4 <= bytes.count else { return nil }
                    r = bytes[p]; g = bytes[p + 1]; b = bytes[p + 2]; a = bytes[p + 3]; p += 4
                } else {
                    switch op >> 6 {
                    case 0:
                        let i = Int(op) * 4
                        r = seen[i]; g = seen[i + 1]; b = seen[i + 2]; a = seen[i + 3]
                    case 1:
                        r = r &+ ((op >> 4) & 3) &- 2
                        g = g &+ ((op >> 2) & 3) &- 2
                        b = b &+ (op & 3) &- 2
                    case 2:
                        guard p < bytes.count else { return nil }
                        let dg = (op & 0x3F) &- 32
                        let next = bytes[p]; p += 1
                        r = r &+ dg &+ (next >> 4) &- 8
                        g = g &+ dg
                        b = b &+ dg &+ (next & 0x0F) &- 8
                    default:
                        run = Int(op & 0x3F)
                    }
                }
                let h = (Int(r) * 3 + Int(g) * 5 + Int(b) * 7 + Int(a) * 11) % 64 * 4
                seen[h] = r; seen[h + 1] = g; seen[h + 2] = b; seen[h + 3] = a
            }
            // Image pixels are premultiplied; QOI stores straight alpha.
            let o = pixel * 4
            out[o] = UInt8(Int(r) * Int(a) / 255)
            out[o + 1] = UInt8(Int(g) * Int(a) / 255)
            out[o + 2] = UInt8(Int(b) * Int(a) / 255)
            out[o + 3] = a
            pixel += 1
        }
        return Image(width: width, height: height, pixels: out)
    }

    // MARK: Windows DIB

    /// Decodes a BITMAPINFOHEADER-based bitmap (24/32-bit, or 8-bit with palette).
    /// `headerOffset` points at the 40-byte header; pixels follow the palette.
    public static func dib(_ data: Data, headerOffset h: Int, pixelsOffset: Int? = nil) -> Image? {
        let r = BinaryReader(data)
        guard let hsize = r.peekU32(at: h), hsize >= 40, hsize < 256,
              let wRaw = r.peekU32(at: h + 4), let hRaw = r.peekU32(at: h + 8),
              let bpp = r.peekU16(at: h + 14), let comp = r.peekU32(at: h + 16) else { return nil }
        let width = Int(Int32(bitPattern: wRaw))
        let heightSigned = Int(Int32(bitPattern: hRaw))
        let height = abs(heightSigned)
        let topDown = heightSigned < 0
        guard width > 0, height > 0, width <= 8192, height <= 8192, comp == 0 || comp == 3 else { return nil }
        guard bpp == 24 || bpp == 32 || bpp == 8 else { return nil }
        var paletteCount = 0
        if bpp == 8 {
            let used = Int(r.peekU32(at: h + 32) ?? 0)
            paletteCount = used == 0 ? 256 : used
        }
        let paletteOffset = h + Int(hsize) + (comp == 3 ? 12 : 0)
        let pix = pixelsOffset ?? (paletteOffset + paletteCount * 4)
        let rowBytes = ((width * Int(bpp) + 31) / 32) * 4
        guard pix + rowBytes * height <= data.count else { return nil }
        return data.withUnsafeBytes { raw -> Image in
            makeImage(width: width, height: height) { x, y in
                let row = topDown ? y : (height - 1 - y)
                let o = pix + row * rowBytes
                switch bpp {
                case 8:
                    let idx = Int(raw[o + x])
                    let p = paletteOffset + idx * 4
                    return p + 2 < data.count ? (raw[p + 2], raw[p + 1], raw[p]) : (0, 0, 0)
                case 24:
                    let q = o + x * 3
                    return (raw[q + 2], raw[q + 1], raw[q])
                default:
                    let q = o + x * 4
                    return (raw[q + 2], raw[q + 1], raw[q])
                }
            }
        }
    }

    // MARK: Embedded PNG search

    /// Finds PNG streams embedded anywhere in `data` and returns the one with the
    /// largest pixel area (at least `minSide` px on each side).
    public static func largestEmbeddedPNG(_ data: Data, minSide: Int = 32, limit: Int = 64 << 20) -> Data? {
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let n = min(data.count, limit)
        var best: (area: Int, range: Range<Int>)? = nil
        data.withUnsafeBytes { raw in
            var i = 0
            while i + 33 < n {
                if raw[i] == 0x89 && raw[i + 1] == 0x50 {
                    var match = true
                    for k in 2..<8 where raw[i + k] != sig[k] { match = false; break }
                    if match, let (area, end) = pngExtent(raw, start: i, minSide: minSide) {
                        if best == nil || area > best!.area { best = (area, i..<end) }
                        i = end
                        continue
                    }
                }
                i += 1
            }
        }
        guard let b = best else { return nil }
        let s = data.startIndex
        return data.subdata(in: (s + b.range.lowerBound)..<(s + b.range.upperBound))
    }

    /// The first complete PNG in `data` (at least `minSide` px).
    public static func firstEmbeddedPNG(_ data: Data, minSide: Int = 32) -> Data? {
        let n = data.count
        return data.withUnsafeBytes { raw -> Data? in
            var i = 0
            while i + 33 < n {
                if raw[i] == 0x89 && raw[i + 1] == 0x50 && raw[i + 2] == 0x4E && raw[i + 3] == 0x47
                    && raw[i + 4] == 0x0D && raw[i + 5] == 0x0A && raw[i + 6] == 0x1A && raw[i + 7] == 0x0A,
                   let (_, end) = pngExtent(raw, start: i, minSide: minSide) {
                    return data.subdata(in: (data.startIndex + i)..<(data.startIndex + end))
                }
                i += 1
            }
            return nil
        }
    }

    /// Walks PNG chunks from `start`; returns (pixel area, end offset) if a complete PNG is found.
    static func pngExtent(_ raw: UnsafeRawBufferPointer, start: Int, minSide: Int) -> (Int, Int)? {
        func be32(_ p: Int) -> Int { Int(raw[p]) << 24 | Int(raw[p + 1]) << 16 | Int(raw[p + 2]) << 8 | Int(raw[p + 3]) }
        var p = start + 8
        guard p + 25 <= raw.count, raw[p + 4] == 0x49, raw[p + 5] == 0x48 else { return nil } // IHDR
        let w = be32(p + 8), h = be32(p + 12)
        guard w >= minSide, h >= minSide, w <= 16384, h <= 16384 else { return nil }
        while p + 12 <= raw.count {
            let len = be32(p)
            guard len >= 0, len < 1 << 28 else { return nil }
            let isEnd = raw[p + 4] == 0x49 && raw[p + 5] == 0x45 && raw[p + 6] == 0x4E && raw[p + 7] == 0x44
            p += 12 + len
            if isEnd { return p <= raw.count ? (w * h, p) : nil }
        }
        return nil
    }

    /// Finds a complete JPEG (SOI ... EOI) starting at `start`.
    static func jpegAt(_ data: Data, start: Int) -> Data? {
        guard start + 4 < data.count else { return nil }
        let s = data.startIndex
        return data.withUnsafeBytes { raw -> Data? in
            guard raw[start] == 0xFF, raw[start + 1] == 0xD8 else { return nil }
            var i = start + 2
            while i + 1 < raw.count {
                if raw[i] == 0xFF && raw[i + 1] == 0xD9 { return data.subdata(in: (s + start)..<(s + i + 2)) }
                i += 1
            }
            return nil
        }
    }
}
