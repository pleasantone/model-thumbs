import Foundation

/// PLY (Stanford polygon format): ASCII, binary little-endian and big-endian.
/// Faces become triangles; vertex-only files are treated as point clouds (common for scans).
public enum LoaderPLY {
    enum Format { case ascii, binaryLE, binaryBE }

    struct Property {
        let name: String
        let type: String        // scalar type, or list item type
        let listCountType: String?
    }

    struct Element {
        let name: String
        let count: Int
        var properties: [Property] = []
    }

    static func size(of type: String) -> Int {
        switch type {
        case "char", "uchar", "int8", "uint8": return 1
        case "short", "ushort", "int16", "uint16": return 2
        case "int", "uint", "float", "int32", "uint32", "float32": return 4
        case "double", "float64": return 8
        default: return 0
        }
    }

    public static func load(_ data: Data) throws -> Mesh {
        // Parse header
        guard let headerEnd = findHeaderEnd(data) else { throw ModelError.malformed("ply: no end_header") }
        let header = String(decoding: data.prefix(headerEnd.textEnd), as: UTF8.self)
        var format = Format.ascii
        var elements: [Element] = []
        for rawLine in header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let key = parts.first else { continue }
            switch key {
            case "format":
                if parts.count > 1 {
                    switch parts[1] {
                    case "binary_little_endian": format = .binaryLE
                    case "binary_big_endian": format = .binaryBE
                    default: format = .ascii
                    }
                }
            case "element":
                if parts.count >= 3 { elements.append(Element(name: parts[1], count: max(0, Int(parts[2]) ?? 0))) }
            case "property":
                guard !elements.isEmpty else { continue }
                if parts.count >= 5 && parts[1] == "list" {
                    elements[elements.count - 1].properties.append(Property(name: parts[4], type: parts[3], listCountType: parts[2]))
                } else if parts.count >= 3 {
                    elements[elements.count - 1].properties.append(Property(name: parts[2], type: parts[1], listCountType: nil))
                }
            default: break
            }
        }

        var mesh = Mesh()
        if format == .ascii {
            try readASCII(data, from: headerEnd.bodyStart, elements: elements, into: &mesh)
        } else {
            try readBinary(data, from: headerEnd.bodyStart, bigEndian: format == .binaryBE, elements: elements, into: &mesh)
        }
        if mesh.isEmpty { throw ModelError.empty }
        mesh.sanitize()
        return mesh
    }

    static func findHeaderEnd(_ data: Data) -> (textEnd: Int, bodyStart: Int)? {
        let marker = Array("end_header".utf8)
        let limit = min(data.count, 1 << 16)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Int, Int)? in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + marker.count <= limit {
                if p[i] == marker[0] {
                    var ok = true
                    for k in 1..<marker.count where p[i + k] != marker[k] { ok = false; break }
                    if ok {
                        var j = i + marker.count
                        while j < data.count && p[j] != 10 { j += 1 }
                        return (i + marker.count, min(j + 1, data.count))
                    }
                }
                i += 1
            }
            return nil
        }
    }

    static func readASCII(_ data: Data, from start: Int, elements: [Element], into mesh: inout Mesh) throws {
        let b = TextBuffer(data)
        var pos = start
        var end = 0
        @inline(__always) func num() -> Double {
            while pos < b.count, b[pos] == 32 || b[pos] == 9 || b[pos] == 10 || b[pos] == 13 { pos += 1 }
            if let v = b.parseDouble(at: pos, end: &end) { pos = end; return v }
            pos += 1
            return 0
        }
        @inline(__always) func int() -> Int {
            let v = num()
            return v.isFinite && abs(v) < 1e15 ? Int(v) : 0
        }
        for el in elements {
            let isVertex = el.name == "vertex"
            let isFace = el.name == "face"
            let xi = el.properties.firstIndex { $0.name == "x" }
            let yi = el.properties.firstIndex { $0.name == "y" }
            let zi = el.properties.firstIndex { $0.name == "z" }
            for _ in 0..<el.count {
                // The header can declare more records than the body holds.
                if pos >= b.count { return }
                var x = 0.0, y = 0.0, z = 0.0
                for (pi, prop) in el.properties.enumerated() {
                    if prop.listCountType != nil {
                        let cnt = int()
                        var ids: [Int] = []
                        ids.reserveCapacity(min(max(0, cnt), max(0, b.count - pos)))
                        for _ in 0..<max(0, cnt) {
                            if pos >= b.count { break }
                            ids.append(int())
                        }
                        if isFace && (prop.name == "vertex_indices" || prop.name == "vertex_index") {
                            addPolygon(ids, &mesh)
                        }
                    } else {
                        let v = num()
                        if isVertex {
                            if pi == xi { x = v } else if pi == yi { y = v } else if pi == zi { z = v }
                        }
                    }
                }
                if isVertex { mesh.addVertex(Float(x), Float(y), Float(z)) }
            }
        }
    }

    static func readBinary(_ data: Data, from start: Int, bigEndian: Bool, elements: [Element], into mesh: inout Mesh) throws {
        var r = BinaryReader(data, bigEndian: bigEndian)
        r.offset = start

        func read(_ type: String) -> Double? {
            switch type {
            case "char", "int8": return r.i8().map(Double.init)
            case "uchar", "uint8": return r.u8().map(Double.init)
            case "short", "int16": return r.i16().map(Double.init)
            case "ushort", "uint16": return r.u16().map(Double.init)
            case "int", "int32": return r.i32().map(Double.init)
            case "uint", "uint32": return r.u32().map(Double.init)
            case "float", "float32": return r.f32().map(Double.init)
            case "double", "float64": return r.f64()
            default: return nil
            }
        }

        for el in elements {
            let isVertex = el.name == "vertex"
            let isFace = el.name == "face"
            let allScalar = el.properties.allSatisfy { $0.listCountType == nil }
            // Fast path for vertices with fixed-size records
            if isVertex && allScalar {
                var offsets: [String: (Int, String)] = [:]
                var stride = 0
                for p in el.properties {
                    offsets[p.name] = (stride, p.type)
                    let s = size(of: p.type)
                    guard s > 0 else { throw ModelError.unsupported("ply type \(p.type)") }
                    stride += s
                }
                guard let (xo, xt) = offsets["x"], let (yo, yt) = offsets["y"], let (zo, zt) = offsets["z"] else {
                    r.offset += stride * el.count
                    continue
                }
                guard r.offset + stride * el.count <= data.count else { throw ModelError.malformed("ply: truncated vertices") }
                mesh.positions.reserveCapacity(el.count * 3)
                let base = r.offset
                let allFloat = xt.hasPrefix("float") && yt.hasPrefix("float") && zt.hasPrefix("float")
                    && size(of: xt) == 4 && size(of: yt) == 4 && size(of: zt) == 4
                if allFloat {
                    data.withUnsafeBytes { raw in
                        for i in 0..<el.count {
                            let rec = base + i * stride
                            var xb = raw.loadUnaligned(fromByteOffset: rec + xo, as: UInt32.self)
                            var yb = raw.loadUnaligned(fromByteOffset: rec + yo, as: UInt32.self)
                            var zb = raw.loadUnaligned(fromByteOffset: rec + zo, as: UInt32.self)
                            if bigEndian { xb = xb.byteSwapped; yb = yb.byteSwapped; zb = zb.byteSwapped }
                            mesh.positions.append(Float(bitPattern: xb))
                            mesh.positions.append(Float(bitPattern: yb))
                            mesh.positions.append(Float(bitPattern: zb))
                        }
                    }
                    r.offset = base + stride * el.count
                } else {
                    for i in 0..<el.count {
                        let rec = base + i * stride
                        r.offset = rec + xo; let x = read(xt) ?? 0
                        r.offset = rec + yo; let y = read(yt) ?? 0
                        r.offset = rec + zo; let z = read(zt) ?? 0
                        mesh.addVertex(Float(x), Float(y), Float(z))
                    }
                    r.offset = base + stride * el.count
                }
                continue
            }
            var ids: [Int] = []
            for _ in 0..<el.count {
                var x = 0.0, y = 0.0, z = 0.0
                for prop in el.properties {
                    if let ct = prop.listCountType {
                        guard let cntD = read(ct) else { return }
                        let cnt = Int(cntD)
                        ids.removeAll(keepingCapacity: true)
                        for _ in 0..<max(0, cnt) {
                            guard let v = read(prop.type) else { return }
                            ids.append(Int(v))
                        }
                        if isFace && (prop.name == "vertex_indices" || prop.name == "vertex_index") {
                            addPolygon(ids, &mesh)
                        }
                    } else {
                        guard let v = read(prop.type) else { return }
                        if isVertex {
                            switch prop.name { case "x": x = v; case "y": y = v; case "z": z = v; default: break }
                        }
                    }
                }
                if isVertex { mesh.addVertex(Float(x), Float(y), Float(z)) }
            }
        }
    }

    @inline(__always)
    static func addPolygon(_ ids: [Int], _ mesh: inout Mesh) {
        guard ids.count >= 3 else { return }
        for k in 1..<(ids.count - 1) where ids[0] >= 0 && ids[k] >= 0 && ids[k + 1] >= 0 {
            mesh.addTriangle(UInt32(ids[0]), UInt32(ids[k]), UInt32(ids[k + 1]))
        }
    }
}
