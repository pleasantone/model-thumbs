import Foundation

/// PCD (Point Cloud Library) and LAS (LiDAR) point clouds.
public enum LoaderPointClouds {
    static let maxPoints = 3_000_000

    // MARK: - PCD

    public static func loadPCD(_ data: Data) throws -> Mesh {
        // Header lines until DATA
        var fields: [String] = [], sizes: [Int] = [], types: [String] = [], counts: [Int] = []
        var points = 0, width = 0, height = 1
        var mode = ""
        var bodyStart = 0
        var lineStart = 0
        let bytes = data.prefix(1 << 16)
        for (i, c) in bytes.enumerated() where c == 10 {
            let line = String(decoding: data[(data.startIndex + lineStart)..<(data.startIndex + i)], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineStart = i + 1
            let parts = line.split(separator: " ").map(String.init)
            guard let key = parts.first, !key.hasPrefix("#") else { continue }
            let rest = Array(parts.dropFirst())
            switch key.uppercased() {
            case "FIELDS": fields = rest
            case "SIZE": sizes = rest.compactMap { Int($0) }
            case "TYPE": types = rest
            case "COUNT": counts = rest.compactMap { Int($0) }
            case "WIDTH": width = Int(rest.first ?? "") ?? 0
            case "HEIGHT": height = Int(rest.first ?? "") ?? 1
            case "POINTS": points = Int(rest.first ?? "") ?? 0
            case "DATA": mode = rest.first?.lowercased() ?? ""; bodyStart = i + 1
            default: break
            }
            if !mode.isEmpty { break }
        }
        guard !mode.isEmpty, !fields.isEmpty else { throw ModelError.malformed("pcd header") }
        if counts.count != fields.count { counts = Array(repeating: 1, count: fields.count) }
        if sizes.count != fields.count { sizes = Array(repeating: 4, count: fields.count) }
        if types.count != fields.count { types = Array(repeating: "F", count: fields.count) }
        if points == 0 { points = width * height }
        // value() reads with unchecked loads, so every field layout has to be valid before it runs.
        guard points > 0 else { throw ModelError.malformed("pcd point count") }
        for f in 0..<fields.count {
            let type = types[f].uppercased()
            guard counts[f] >= 1, counts[f] <= 1 << 20,
                  type == "F" ? (sizes[f] == 4 || sizes[f] == 8)
                              : ((type == "I" || type == "U") && [1, 2, 4, 8].contains(sizes[f])) else {
                throw ModelError.malformed("pcd field layout")
            }
        }
        guard let xi = fields.firstIndex(of: "x"), let yi = fields.firstIndex(of: "y"), let zi = fields.firstIndex(of: "z") else {
            throw ModelError.unsupported("pcd without x/y/z")
        }
        let stride = max(1, (points + maxPoints - 1) / maxPoints)
        var mesh = Mesh()

        func value(_ raw: UnsafeRawBufferPointer, _ o: Int, _ f: Int) -> Double {
            switch (types[f].uppercased(), sizes[f]) {
            case ("F", 8): return raw.loadUnaligned(fromByteOffset: o, as: Double.self)
            case ("F", _): return Double(raw.loadUnaligned(fromByteOffset: o, as: Float.self))
            case ("I", 1): return Double(raw.load(fromByteOffset: o, as: Int8.self))
            case ("I", 2): return Double(raw.loadUnaligned(fromByteOffset: o, as: Int16.self))
            case ("I", 8): return Double(raw.loadUnaligned(fromByteOffset: o, as: Int64.self))
            case ("I", _): return Double(raw.loadUnaligned(fromByteOffset: o, as: Int32.self))
            case ("U", 1): return Double(raw.load(fromByteOffset: o, as: UInt8.self))
            case ("U", 2): return Double(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
            case ("U", 8): return Double(raw.loadUnaligned(fromByteOffset: o, as: UInt64.self))
            default: return Double(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
            }
        }

        switch mode {
        case "ascii":
            // flattened column index for each field
            var col = [Int](repeating: 0, count: fields.count)
            for f in 1..<max(1, fields.count) { col[f] = col[f - 1] + counts[f - 1] }
            let b = TextBuffer(data.subdata(in: (data.startIndex + bodyStart)..<data.endIndex))
            var pos = 0, end = 0, row = 0
            let need = max(col[xi], col[yi], col[zi])
            var vals = [Double](repeating: 0, count: need + 1)
            while pos < b.count && row < points {
                var k = 0
                var ok = true
                while k <= need {
                    b.skipSpaces(&pos)
                    if pos >= b.count || b[pos] == 10 { ok = false; break }
                    if let v = b.parseDouble(at: pos, end: &end) { vals[k] = v; pos = end } else { ok = false; break }
                    k += 1
                }
                if ok && row % stride == 0 { mesh.addVertex(Float(vals[col[xi]]), Float(vals[col[yi]]), Float(vals[col[zi]])) }
                b.skipToNextLine(&pos)
                row += 1
            }
        case "binary":
            var off = [Int](repeating: 0, count: fields.count)
            for f in 1..<max(1, fields.count) { off[f] = off[f - 1] + sizes[f - 1] * counts[f - 1] }
            let recSize = off[fields.count - 1] + sizes[fields.count - 1] * counts[fields.count - 1]
            let n = min(points, (data.count - bodyStart) / max(recSize, 1))
            data.withUnsafeBytes { raw in
                var i = 0
                while i < n {
                    let o = bodyStart + i * recSize
                    mesh.addVertex(Float(value(raw, o + off[xi], xi)), Float(value(raw, o + off[yi], yi)), Float(value(raw, o + off[zi], zi)))
                    i += stride
                }
            }
        case "binary_compressed":
            let r = BinaryReader(data)
            guard let csize = r.peekU32(at: bodyStart), let usize = r.peekU32(at: bodyStart + 4),
                  bodyStart + 8 + Int(csize) <= data.count,
                  Int(usize) <= Int(csize) * 264 else { throw ModelError.malformed("pcd compressed header") }
            let s = data.startIndex + bodyStart + 8
            let raw = lzfDecompress(data[s..<(s + Int(csize))], outputSize: Int(usize))
            guard raw.count == Int(usize) else { throw ModelError.malformed("pcd lzf") }
            // Structure-of-arrays: each field's values for all points are contiguous.
            var base = [Int](repeating: 0, count: fields.count)
            for f in 1..<max(1, fields.count) { base[f] = base[f - 1] + sizes[f - 1] * counts[f - 1] * points }
            let last = fields.count - 1
            guard base[last] + sizes[last] * counts[last] * points <= raw.count else {
                throw ModelError.malformed("pcd compressed body is too short")
            }
            raw.withUnsafeBytes { buf in
                var i = 0
                while i < points {
                    let x = value(buf, base[xi] + i * sizes[xi] * counts[xi], xi)
                    let y = value(buf, base[yi] + i * sizes[yi] * counts[yi], yi)
                    let z = value(buf, base[zi] + i * sizes[zi] * counts[zi], zi)
                    mesh.addVertex(Float(x), Float(y), Float(z))
                    i += stride
                }
            }
        default:
            throw ModelError.unsupported("pcd DATA \(mode)")
        }
        if mesh.isEmpty { throw ModelError.empty }
        return mesh
    }

    /// liblzf decompression.
    static func lzfDecompress(_ input: Data, outputSize: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: outputSize)
        var op = 0
        let ok: Bool = input.withUnsafeBytes { raw -> Bool in
            var ip = 0
            let n = raw.count
            while ip < n {
                let ctrl = Int(raw[ip]); ip += 1
                if ctrl < 32 {
                    let len = ctrl + 1
                    guard ip + len <= n, op + len <= outputSize else { return false }
                    for k in 0..<len { out[op + k] = raw[ip + k] }
                    ip += len; op += len
                } else {
                    var len = ctrl >> 5
                    var ref = op - ((ctrl & 0x1F) << 8) - 1
                    if len == 7 { guard ip < n else { return false }; len += Int(raw[ip]); ip += 1 }
                    guard ip < n else { return false }
                    ref -= Int(raw[ip]); ip += 1
                    len += 2
                    guard ref >= 0, op + len <= outputSize else { return false }
                    for _ in 0..<len { out[op] = out[ref]; op += 1; ref += 1 }
                }
            }
            return true
        }
        if !ok { return [] }
        out.removeLast(outputSize - op)
        return out
    }

    // MARK: - LAS

    public static func loadLAS(_ data: Data) throws -> Mesh {
        let r = BinaryReader(data)
        guard data.starts(with: Array("LASF".utf8)), let pointOffset = r.peekU32(at: 96) else {
            throw ModelError.malformed("not a LAS file")
        }
        let format = data[data.startIndex + 104]
        if format & 0xC0 != 0 { throw ModelError.unsupported("compressed LAZ data") }
        guard let recLen = r.peekU16(at: 105), recLen >= 12 else { throw ModelError.malformed("las record length") }
        var count = Int(r.peekU32(at: 107) ?? 0)
        let headerSize = Int(r.peekU16(at: 94) ?? 227)
        if headerSize >= 375 {
            let c64 = Int(UInt64(r.peekU32(at: 247) ?? 0) | UInt64(r.peekU32(at: 251) ?? 0) << 32)
            if c64 > 0 { count = c64 }
        }
        func dbl(_ at: Int) -> Double { Double(bitPattern: UInt64(r.peekU32(at: at) ?? 0) | UInt64(r.peekU32(at: at + 4) ?? 0) << 32) }
        let sx = dbl(131), sy = dbl(139), sz = dbl(147)
        let ox = dbl(155), oy = dbl(163), oz = dbl(171)
        let rl = Int(recLen), base = Int(pointOffset)
        count = min(count, (data.count - base) / rl)
        guard count > 0 else { throw ModelError.empty }
        let stride = max(1, (count + maxPoints - 1) / maxPoints)
        var mesh = Mesh()
        mesh.positions.reserveCapacity(count / stride * 3 + 3)
        _ = (ox, oy, oz) // header offsets only shift the cloud; dropped to keep float precision
        data.withUnsafeBytes { raw in
            // Recentre on the first point (in integer units) so georeferenced data stays precise.
            let x0 = Int64(raw.loadUnaligned(fromByteOffset: base, as: Int32.self))
            let y0 = Int64(raw.loadUnaligned(fromByteOffset: base + 4, as: Int32.self))
            let z0 = Int64(raw.loadUnaligned(fromByteOffset: base + 8, as: Int32.self))
            var i = 0
            while i < count {
                let o = base + i * rl
                let x = Double(Int64(raw.loadUnaligned(fromByteOffset: o, as: Int32.self)) - x0) * sx
                let y = Double(Int64(raw.loadUnaligned(fromByteOffset: o + 4, as: Int32.self)) - y0) * sy
                let z = Double(Int64(raw.loadUnaligned(fromByteOffset: o + 8, as: Int32.self)) - z0) * sz
                mesh.addVertex(Float(x), Float(y), Float(z))
                i += stride
            }
        }
        return mesh
    }
}
