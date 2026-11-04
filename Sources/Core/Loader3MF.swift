import Foundation

/// 3MF (3D Manufacturing Format): a ZIP with XML model parts.
/// Handles plain meshes, components, the Production extension (p:path)
/// used by Bambu Studio / Orca, and the embedded thumbnail.
public enum Loader3MF {
    /// The largest real preview in the archive. The file's declared thumbnail is often a small
    /// copy (240x180 from MakerWorld) of an image that's also stored at 680x510.
    public static func embeddedThumbnail(_ zip: ZipArchive) -> Data? {
        var candidates: [String] = []
        if let rels = try? zip.extract(named: "_rels/.rels") {
            for rel in relationships(rels) where rel.type.lowercased().hasSuffix("/thumbnail") {
                candidates.append(rel.target)
            }
        }
        candidates += ["Metadata/plate_1.png", "Metadata/thumbnail.png", "Metadata/Thumbnail.png",
                       "Metadata/thumbnail.jpg", "Metadata/plate_1.jpg"]
        // Other previews, except picking / helper masks
        for e in zip.entries {
            let n = e.name.lowercased()
            guard n.hasPrefix("metadata/") || n.hasPrefix("auxiliaries/.thumbnails/"),
                  n.hasSuffix(".png") || n.hasSuffix(".jpg") else { continue }
            if n.contains("pick") || n.contains("_no_light") || n.contains("small") || n.contains("top_") { continue }
            candidates.append(e.name)
        }
        // Ties keep the earlier candidate, so plate 1 beats the other plates.
        var best: (data: Data, area: Int)? = nil
        for c in candidates {
            guard let e = zip.entry(named: c), e.uncompressedSize <= 64 << 20,
                  let d = try? zip.extract(e), d.isPNG || d.isJPEG, d.count > 100 else { continue }
            let size = imageSize(d)
            let area = size.map { $0.width * $0.height } ?? 0
            if best == nil || area > best!.area { best = (d, area) }
        }
        return best?.data
    }

    /// Pixel size from a PNG or JPEG header.
    public static func imageSize(_ data: Data) -> (width: Int, height: Int)? {
        let r = BinaryReader(data, bigEndian: true)
        if data.isPNG {
            guard let w = r.peekU32(at: 16), let h = r.peekU32(at: 20),
                  w <= 1 << 16, h <= 1 << 16 else { return nil }
            return (Int(w), Int(h))
        }
        guard data.isJPEG else { return nil }
        var p = 2
        while p + 9 <= data.count {
            guard data[data.startIndex + p] == 0xFF else { p += 1; continue }
            let marker = data[data.startIndex + p + 1]
            guard let len = r.peekU16(at: p + 2) else { return nil }
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                guard let h = r.peekU16(at: p + 5), let w = r.peekU16(at: p + 7) else { return nil }
                return (Int(w), Int(h))
            }
            p += 2 + Int(len)
        }
        return nil
    }

    struct Relationship { let type: String; let target: String }

    static func relationships(_ data: Data) -> [Relationship] {
        var out: [Relationship] = []
        var s = XMLScanner(TextBuffer(data))
        while true {
            let ev = s.next()
            if case .eof = ev { break }
            if case .start = ev, s.nameIs("Relationship"),
               let t = s.attribute("Type"), let target = s.attribute("Target") {
                out.append(Relationship(type: t, target: target))
            }
        }
        return out
    }

    public static func loadMesh(_ zip: ZipArchive) throws -> Mesh {
        var rootPath = "3D/3dmodel.model"
        if let rels = try? zip.extract(named: "_rels/.rels") {
            for rel in relationships(rels) where rel.type.lowercased().hasSuffix("/3dmodel") {
                rootPath = rel.target
                break
            }
        }
        if zip.entry(named: rootPath) == nil {
            // Fall back to any .model file
            guard let any = zip.entries.first(where: { $0.name.lowercased().hasSuffix(".model") }) else {
                throw ModelError.malformed("3mf: no model part")
            }
            rootPath = any.name
        }
        var ctx = Context(zip: zip)
        ctx.colors = slicerColors(zip)
        let root = try ctx.part(rootPath)
        var result = Mesh()
        result.palette = ctx.colors.palette
        var items = root.buildItems.isEmpty
            ? root.objects.keys.sorted().map { BuildItem(objectID: $0, path: nil, transform: .identity) }
            : root.buildItems
        // Slicer projects lay plates out side by side, which would shrink and scatter the render.
        let firstPlate = firstPlateObjects(zip)
        let onFirstPlate = items.filter { firstPlate.contains($0.objectID) }
        if !onFirstPlate.isEmpty { items = onFirstPlate }
        for item in items {
            let path = item.path ?? rootPath
            try ctx.appendObject(item.objectID, inPart: path, transform: item.transform, into: &result, depth: 0,
                                 color: ctx.colors.index(object: item.objectID, part: nil, inherited: 0))
        }
        if result.isEmpty { throw ModelError.empty }
        result.sanitize()
        return result
    }

    // MARK: - Internals

    struct Component { let objectID: Int; let path: String?; let transform: Transform }
    struct Object { var mesh: Mesh? ; var components: [Component] = [] }
    struct BuildItem { let objectID: Int; let path: String?; let transform: Transform }
    struct Part { var objects: [Int: Object] = [:]; var buildItems: [BuildItem] = [] }

    /// Filament colours and assignments saved by Bambu Studio and OrcaSlicer.
    struct SlicerColors {
        var palette: [(Float, Float, Float)] = []
        var objectExtruder: [Int: Int] = [:]
        var partExtruder: [Int: [Int: Int]] = [:]

        /// Palette index for an object or one of its parts. Extruders count from 1, and
        /// 0 or a missing value means "use the parent's".
        func index(object: Int, part: Int?, inherited: UInt8) -> UInt8 {
            let extruder = part.flatMap { partExtruder[object]?[$0] } ?? objectExtruder[object] ?? 0
            guard extruder >= 1, extruder <= palette.count else { return inherited }
            return UInt8(extruder - 1)
        }
    }

    /// "#RRGGBB" or "#RRGGBBAA" as a display colour. The range is pulled in so black filament
    /// still shows its shape under the lights and white doesn't blow out.
    static func displayColor(_ hex: String) -> (Float, Float, Float)? {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.utf8.count == 6 || h.utf8.count == 8, let v = UInt32(h.prefix(6), radix: 16) else { return nil }
        func channel(_ shift: UInt32) -> Float { 0.22 + 0.63 * Float((v >> shift) & 0xFF) / 255 }
        return (channel(16), channel(8), channel(0))
    }

    /// Object IDs on plate 1 of a Bambu Studio or OrcaSlicer project. Empty when there's no plate data.
    static func firstPlateObjects(_ zip: ZipArchive) -> Set<Int> {
        guard let model = try? zip.extract(named: "Metadata/model_settings.config") else { return [] }
        var s = XMLScanner(TextBuffer(model))
        var inPlate = false
        var plateID: Int? = nil
        var objects = Set<Int>()
        while true {
            let ev = s.next()
            if case .eof = ev { return [] }
            if case .start = ev {
                if s.nameIs("plate") {
                    inPlate = !s.selfClosing
                    plateID = nil
                    objects = []
                } else if inPlate, s.nameIs("metadata"), let key = s.attribute("key"),
                          let value = s.attribute("value").flatMap({ Int($0) }) {
                    if key == "plater_id" { plateID = value } else if key == "object_id" { objects.insert(value) }
                }
            } else if case .end = ev, s.nameIs("plate") {
                if plateID == 1 { return objects }
                inPlate = false
            }
        }
    }

    static func slicerColors(_ zip: ZipArchive) -> SlicerColors {
        var result = SlicerColors()
        guard let settings = try? zip.extract(named: "Metadata/project_settings.config"),
              let json = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let colours = json["filament_colour"] as? [String], colours.count <= 200 else { return result }
        // A filament with an unreadable colour keeps its slot so the numbering stays right.
        let fallback: (Float, Float, Float) = (0.56, 0.66, 0.78)
        result.palette = colours.map { displayColor($0) ?? fallback }
        guard let model = try? zip.extract(named: "Metadata/model_settings.config") else { return result }
        var s = XMLScanner(TextBuffer(model))
        var object: Int? = nil
        var part: Int? = nil
        while true {
            let ev = s.next()
            if case .eof = ev { return result }
            if case .start = ev {
                if s.nameIs("object") {
                    object = s.selfClosing ? nil : s.intAttribute("id")
                    part = nil
                } else if s.nameIs("part") {
                    part = s.selfClosing ? nil : s.intAttribute("id")
                } else if s.nameIs("metadata"), s.attribute("key") == "extruder",
                          let o = object, let value = s.attribute("value"), let extruder = Int(value) {
                    if let p = part {
                        result.partExtruder[o, default: [:]][p] = extruder
                    } else {
                        result.objectExtruder[o] = extruder
                    }
                }
            } else if case .end = ev {
                if s.nameIs("part") { part = nil } else if s.nameIs("object") { object = nil; part = nil }
            }
        }
    }

    struct Context {
        let zip: ZipArchive
        var parts: [String: Part] = [:]
        var colors = SlicerColors()

        mutating func part(_ path: String) throws -> Part {
            let key = ZipArchive.normalize(path)
            if let p = parts[key] { return p }
            guard let data = try zip.extract(named: path) else {
                throw ModelError.malformed("3mf: missing part \(path)")
            }
            let p = Loader3MF.parsePart(data)
            parts[key] = p
            return p
        }

        mutating func appendObject(_ id: Int, inPart path: String, transform: Transform,
                                   into out: inout Mesh, depth: Int, color: UInt8) throws {
            guard depth < 16 else { return }
            let p = try part(path)
            guard let obj = p.objects[id] else { return }
            if let m = obj.mesh, !m.isEmpty {
                out.append(m, transform: transform)
                if !colors.palette.isEmpty {
                    out.triangleColors.append(contentsOf: repeatElement(color, count: m.triangleCount))
                }
            }
            for c in obj.components {
                // model_settings.config lists a top-level object's components as its parts.
                let partColor = depth == 0 ? colors.index(object: id, part: c.objectID, inherited: color) : color
                try appendObject(c.objectID, inPart: c.path ?? path, transform: c.transform.then(transform),
                                 into: &out, depth: depth + 1, color: partColor)
            }
        }
    }

    static func parseTransform(_ s: String?) -> Transform {
        guard let s = s else { return .identity }
        let nums = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "," }).compactMap { Float($0) }
        return nums.count == 12 ? Transform(m: nums) : .identity
    }

    static func parsePart(_ data: Data) -> Part {
        var part = Part()
        var s = XMLScanner(TextBuffer(data))
        var currentID: Int? = nil
        var current = Object()
        var mesh = Mesh()
        var inMesh = false
        while true {
            let ev = s.next()
            switch ev {
            case .eof:
                return part
            case .start:
                if s.nameIs("vertex") {
                    if inMesh {
                        var x = 0.0, y = 0.0, z = 0.0
                        var e = 0
                        let tb = s.buf
                        s.forEachShortAttribute { c0, c1, vs in
                            guard c1 == 0 else { return }
                            let v = tb.parseDouble(at: vs, end: &e) ?? 0
                            if c0 == 120 { x = v } else if c0 == 121 { y = v } else if c0 == 122 { z = v }
                        }
                        mesh.addVertex(Float(x), Float(y), Float(z))
                    }
                } else if s.nameIs("triangle") {
                    if inMesh {
                        var a = -1, b = -1, c = -1
                        var e = 0
                        let tb = s.buf
                        s.forEachShortAttribute { c0, c1, vs in
                            guard c0 == 118 else { return } // 'v'
                            let v = tb.parseInt(at: vs, end: &e) ?? -1
                            if c1 == 49 { a = v } else if c1 == 50 { b = v } else if c1 == 51 { c = v }
                        }
                        if a >= 0, b >= 0, c >= 0 { mesh.addTriangle(UInt32(a), UInt32(b), UInt32(c)) }
                    }
                } else if s.nameIs("object") {
                    currentID = s.intAttribute("id")
                    current = Object()
                    if s.selfClosing, let id = currentID { part.objects[id] = current; currentID = nil }
                } else if s.nameIs("mesh") {
                    inMesh = true
                    mesh = Mesh()
                } else if s.nameIs("component") {
                    if let oid = s.intAttribute("objectid") {
                        current.components.append(Component(objectID: oid, path: s.attribute("path"),
                                                            transform: parseTransform(s.attribute("transform"))))
                    }
                } else if s.nameIs("item") {
                    if let oid = s.intAttribute("objectid") {
                        part.buildItems.append(BuildItem(objectID: oid, path: s.attribute("path"),
                                                         transform: parseTransform(s.attribute("transform"))))
                    }
                }
            case .end:
                if s.nameIs("mesh") {
                    inMesh = false
                    current.mesh = mesh
                    mesh = Mesh()
                } else if s.nameIs("object") {
                    if let id = currentID { part.objects[id] = current }
                    currentID = nil
                    current = Object()
                }
            case .text:
                break
            }
        }
    }
}
