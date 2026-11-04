import Foundation

/// Extracts the preview image slicers embed in G-code.
/// Text G-code: "; thumbnail begin WxH len" base64 blocks (PrusaSlicer, Orca, Bambu, Cura plugins).
/// Binary G-code (.bgcode): thumbnail blocks (type 5) holding PNG, JPEG or QOI.
public enum LoaderGCode {
    /// PNG or JPEG bytes for an embedded image. QOI is converted, since ImageIO can't read it.
    static func usableImage(_ data: Data) -> Data? {
        if data.isPNG || data.isJPEG { return data }
        return ImageDecode.qoi(data).map { ImageDecode.png($0) }
    }

    public static func thumbnail(_ data: Data) throws -> Data {
        if data.starts(with: Array("GCDE".utf8)) { return try binaryThumbnail(data) }
        return try textThumbnail(data)
    }

    static func textThumbnail(_ data: Data) throws -> Data {
        // Thumbnails live in the header; scan the first 4MB and the last 1MB.
        let head = data.prefix(4 << 20)
        var best: Data? = nil
        var bestArea = 0
        func scan(_ chunk: Data) {
            let text = String(decoding: chunk, as: UTF8.self)
            var searchStart = text.startIndex
            while let begin = text.range(of: "thumbnail", range: searchStart..<text.endIndex) {
                // Accept "; thumbnail begin", "; thumbnail_JPG begin", "; thumbnail_QOI begin"
                guard let lineEnd = text[begin.upperBound...].firstIndex(of: "\n") else { break }
                let line = text[begin.lowerBound..<lineEnd]
                searchStart = lineEnd
                guard line.contains(" begin") else { continue }
                // dimensions "WxH"
                var area = 0
                for tok in line.split(separator: " ") where tok.contains("x") {
                    let wh = tok.split(separator: "x")
                    if wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) { area = w * h; break }
                }
                guard let endR = text.range(of: "thumbnail", range: lineEnd..<text.endIndex),
                      let endLineEnd = text[endR.upperBound...].firstIndex(of: "\n") ?? Optional(text.endIndex) else { break }
                var b64 = ""
                for l in text[lineEnd..<endR.lowerBound].split(separator: "\n") {
                    var s = l.drop(while: { $0 == ";" || $0 == " " })
                    while let last = s.last, last == "\r" || last == " " { s = s.dropLast() }
                    b64 += s
                }
                searchStart = endLineEnd
                if area >= bestArea, let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                   let img = usableImage(raw) {
                    best = img; bestArea = area
                }
            }
        }
        scan(head)
        if best == nil, data.count > head.count { scan(data.suffix(1 << 20)) }
        guard let img = best else { throw ModelError.empty }
        return img
    }

    static func binaryThumbnail(_ data: Data) throws -> Data {
        var r = BinaryReader(data)
        r.offset = 4
        guard let _ = r.u32(), let checksumType = r.u16() else { throw ModelError.malformed("bgcode header") }
        let checksumSize = checksumType == 1 ? 4 : 0
        var best: Data? = nil
        var bestArea = 0
        while r.remaining >= 8 {
            guard let type = r.u16(), let compression = r.u16(), let usize = r.u32() else { break }
            var csize = Int(usize)
            if compression != 0 { guard let c = r.u32() else { break }; csize = Int(c) }
            let paramsSize = type == 5 ? 6 : 2
            let blockStart = r.offset
            if type == 5 {
                guard let format = r.u16(), let w = r.u16(), let h = r.u16() else { break }
                _ = format // the image's own header says what it is
                let area = Int(w) * Int(h)
                if let raw = r.bytes(csize), compression == 0, area >= bestArea, let img = usableImage(raw) {
                    best = img; bestArea = area
                }
            } else if type == 1 && best != nil {
                break // G-code data blocks begin: thumbnails are done
            }
            r.offset = blockStart + paramsSize + csize + checksumSize
        }
        guard let img = best else { throw ModelError.empty }
        return img
    }
}
