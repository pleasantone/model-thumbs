import Foundation

/// glTF 2.0: binary .glb and .gltf with embedded (data:) or neighbouring buffers.
/// Draco / meshopt compressed primitives are skipped.
public enum LoaderGLTF {
    public static func load(_ data: Data, url: URL?) throws -> Mesh {
        var json: [String: Any]
        var bin: Data? = nil
        if data.count >= 12, data.starts(with: [0x67, 0x6C, 0x54, 0x46]) { // "glTF"
            var r = BinaryReader(data)
            r.offset = 12
            var j: Data? = nil
            while r.remaining >= 8 {
                guard let len = r.u32(), let type = r.u32(), let chunk = r.bytes(Int(len)) else { break }
                if type == 0x4E4F534A { j = chunk }          // JSON
                else if type == 0x004E4942 { bin = chunk }   // BIN
                let pad = (4 - Int(len) % 4) % 4
                r.offset += pad
            }
            guard let jd = j, let obj = try JSONSerialization.jsonObject(with: jd) as? [String: Any] else {
                throw ModelError.malformed("glb: no JSON chunk")
            }
            json = obj
        } else {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ModelError.malformed("gltf: bad JSON")
            }
            json = obj
        }

        // Resolve buffers
        let buffersJSON = json["buffers"] as? [[String: Any]] ?? []
        var buffers: [Data?] = []
        for (i, b) in buffersJSON.enumerated() {
            if let uri = b["uri"] as? String {
                if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                    buffers.append(Data(base64Encoded: String(uri[uri.index(after: comma)...])))
                } else if let base = url?.deletingLastPathComponent() {
                    let path = uri.removingPercentEncoding ?? uri
                    // A model may only reference files in its own folder or below it.
                    let root = base.standardizedFileURL.resolvingSymlinksInPath()
                    let target = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                    if target.path.hasPrefix(prefix) {
                        buffers.append(try? Data(contentsOf: target, options: .alwaysMapped))
                    } else {
                        buffers.append(nil)
                    }
                } else {
                    buffers.append(nil)
                }
            } else {
                buffers.append(i == 0 ? bin : nil)
            }
        }

        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        let nodes = json["nodes"] as? [[String: Any]] ?? []

        func accessorData(_ index: Int) -> (data: Data, offset: Int, stride: Int, count: Int, comp: Int, type: String)? {
            guard index >= 0, index < accessors.count else { return nil }
            let a = accessors[index]
            guard let viewIdx = a["bufferView"] as? Int, viewIdx >= 0, viewIdx < views.count else { return nil }
            if a["sparse"] != nil { /* sparse accessors ignored; base data still used */ }
            let v = views[viewIdx]
            guard let bufIdx = v["buffer"] as? Int, bufIdx >= 0, bufIdx < buffers.count, let buf = buffers[bufIdx] else { return nil }
            let comp = a["componentType"] as? Int ?? 5126
            let type = a["type"] as? String ?? "SCALAR"
            let count = a["count"] as? Int ?? 0
            let viewOffset = v["byteOffset"] as? Int ?? 0, accessorOffset = a["byteOffset"] as? Int ?? 0
            guard viewOffset >= 0, accessorOffset >= 0,
                  let ncomp = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][type],
                  let csize = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][comp] else { return nil }
            let offset = viewOffset + accessorOffset
            let stride = (v["byteStride"] as? Int) ?? (ncomp * csize)
            // The reads below are unchecked, so the whole range has to be proven valid here.
            guard count > 0, stride >= ncomp * csize,
                  offset + stride * (count - 1) + ncomp * csize <= buf.count else { return nil }
            return (buf, offset, stride, count, comp, type)
        }

        func primitiveMesh(_ prim: [String: Any]) -> Mesh? {
            let mode = prim["mode"] as? Int ?? 4
            guard mode == 4 || mode == 5 || mode == 6 || mode == 0 else { return nil }
            if let ext = prim["extensions"] as? [String: Any], ext["KHR_draco_mesh_compression"] != nil { return nil }
            guard let attrs = prim["attributes"] as? [String: Any], let posIdx = attrs["POSITION"] as? Int,
                  let pa = accessorData(posIdx), pa.comp == 5126, pa.type == "VEC3" else { return nil }
            var m = Mesh()
            m.positions.reserveCapacity(pa.count * 3)
            pa.data.withUnsafeBytes { raw in
                for i in 0..<pa.count {
                    let o = pa.offset + i * pa.stride
                    m.positions.append(raw.loadUnaligned(fromByteOffset: o, as: Float.self))
                    m.positions.append(raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self))
                    m.positions.append(raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                }
            }
            if mode == 0 { return m } // points
            var idx: [UInt32] = []
            if let ii = prim["indices"] as? Int, let ia = accessorData(ii) {
                guard ia.type == "SCALAR", [5121, 5123, 5125].contains(ia.comp) else { return nil }
                idx.reserveCapacity(ia.count)
                ia.data.withUnsafeBytes { raw in
                    for i in 0..<ia.count {
                        let o = ia.offset + i * ia.stride
                        switch ia.comp {
                        case 5121: idx.append(UInt32(raw.load(fromByteOffset: o, as: UInt8.self)))
                        case 5123: idx.append(UInt32(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)))
                        default: idx.append(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                        }
                    }
                }
            } else {
                idx = (0..<UInt32(pa.count)).map { $0 }
            }
            switch mode {
            case 5: // strip
                if idx.count >= 3 {
                    for i in 0..<(idx.count - 2) {
                        if i % 2 == 0 { m.addTriangle(idx[i], idx[i + 1], idx[i + 2]) }
                        else { m.addTriangle(idx[i + 1], idx[i], idx[i + 2]) }
                    }
                }
            case 6: // fan
                if idx.count >= 3 { for i in 1..<(idx.count - 1) { m.addTriangle(idx[0], idx[i], idx[i + 1]) } }
            default:
                m.indices = idx
                m.indices.removeLast(idx.count % 3)
            }
            return m
        }

        var meshCache: [Int: Mesh] = [:]
        func meshFor(_ i: Int) -> Mesh {
            if let c = meshCache[i] { return c }
            var out = Mesh()
            if i < meshes.count, let prims = meshes[i]["primitives"] as? [[String: Any]] {
                for p in prims { if let pm = primitiveMesh(p) { out.append(pm) } }
            }
            meshCache[i] = out
            return out
        }

        func nums(_ v: Any?) -> [Double]? { (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } }

        var result = Mesh()
        func visit(_ nodeIdx: Int, _ parent: Transform, _ depth: Int) {
            guard depth < 64, nodeIdx >= 0, nodeIdx < nodes.count else { return }
            let n = nodes[nodeIdx]
            var local = Transform.identity
            if let mtx = nums(n["matrix"]), mtx.count == 16 { local = .fromColumnMajor4x4(mtx) }
            else if n["translation"] != nil || n["rotation"] != nil || n["scale"] != nil {
                local = .fromTRS(t: nums(n["translation"]), r: nums(n["rotation"]), s: nums(n["scale"]))
            }
            let world = local.then(parent)
            if let mi = n["mesh"] as? Int { result.append(meshFor(mi), transform: world) }
            for c in (n["children"] as? [Int] ?? []) { visit(c, world, depth + 1) }
        }

        let scenes = json["scenes"] as? [[String: Any]] ?? []
        let sceneIdx = json["scene"] as? Int ?? 0
        if sceneIdx < scenes.count, let roots = scenes[sceneIdx]["nodes"] as? [Int] {
            for r in roots { visit(r, .identity, 0) }
        } else if !nodes.isEmpty {
            // No scene: treat nodes that are nobody's child as roots
            var isChild = Set<Int>()
            for n in nodes { for c in (n["children"] as? [Int] ?? []) { isChild.insert(c) } }
            for i in 0..<nodes.count where !isChild.contains(i) { visit(i, .identity, 0) }
        } else {
            for i in 0..<meshes.count { result.append(meshFor(i)) }
        }
        if result.isEmpty { throw ModelError.empty }
        result.sanitize()
        result.convertYUpToZUp()
        return result
    }
}
