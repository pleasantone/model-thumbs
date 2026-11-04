import Foundation
import QuickLookThumbnailing
import CoreGraphics
import ImageIO

/// Quick Look thumbnail provider: Finder asks this for icons of the file types
/// listed under QLSupportedContentTypes in the extension's Info.plist.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    override init() {
        super.init()
        #if MT_HAS_OCCT
        ModelLoader.cadLoader = CADLoader.load
        #endif
    }

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let defaults = UserDefaults.standard
        var options = ModelLoader.Options()
        if defaults.object(forKey: "PreferEmbedded3MFThumbnail") != nil {
            options.preferEmbeddedThumbnail = defaults.bool(forKey: "PreferEmbedded3MFThumbnail")
        }

        let maxSize = request.maximumSize
        let scale = max(1, request.scale)
        let longest = max(maxSize.width, maxSize.height)
        let pixels = Int(min(1024, max(64, longest * scale)))

        do {
            switch try ModelLoader.load(request.fileURL, options: options) {
            case .image(let data):
                guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    throw ModelError.malformed("embedded image")
                }
                handler(Self.reply(for: cg, maxSize: maxSize), nil)

            case .mesh(let mesh):
                var ro = RenderOptions()
                ro.size = pixels
                ro.supersample = pixels <= 256 ? 3 : 2
                if mesh.triangleCount > 3_000_000 { ro.supersample = min(ro.supersample, 2) }
                // A colour the user chose wins over the colours saved in the file.
                if let hex = defaults.string(forKey: "ModelColor"), let c = Self.parseHex(hex) {
                    ro.color = c
                    ro.useMeshColors = false
                }
                let img = Renderer.render(mesh, options: ro)
                guard let cg = Self.cgImage(img) else { throw ModelError.malformed("render") }
                handler(Self.reply(for: cg, maxSize: maxSize), nil)
            }
        } catch {
            NSLog("ModelThumbs: %@: %@", request.fileURL.lastPathComponent, String(describing: error))
            handler(nil, error)
        }
    }

    /// Aspect-fit the image into the requested size.
    static func reply(for image: CGImage, maxSize: CGSize) -> QLThumbnailReply {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let s = min(maxSize.width / iw, maxSize.height / ih)
        let size = CGSize(width: max(1, (iw * s).rounded()), height: max(1, (ih * s).rounded()))
        return QLThumbnailReply(contextSize: size) { ctx -> Bool in
            ctx.interpolationQuality = .high
            // On a Retina display the context is larger than `size` and isn't scaled to match,
            // so fill whatever area the context really covers.
            ctx.draw(image, in: ctx.boundingBoxOfClipPath)
            return true
        }
    }

    static func cgImage(_ img: Image) -> CGImage? {
        let data = Data(img.pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: img.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func parseHex(_ s: String) -> (Float, Float, Float)? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }
}
