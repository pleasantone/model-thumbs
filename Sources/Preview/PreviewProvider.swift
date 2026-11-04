import CoreGraphics
import Foundation
import ImageIO
import QuickLookUI

/// Quick Look preview provider: what you see when you press space on a file.
/// Shows a large embedded image when the file has one, otherwise renders the model.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    /// Longest side of the preview in points. Rendered models get twice this in pixels.
    static let displaySize: CGFloat = 800
    /// A 3MF image smaller than this looks soft at full size, so the geometry is rendered instead.
    static let minimumSharpImage = 600

    override init() {
        super.init()
        #if MT_HAS_OCCT
        ModelLoader.cadLoader = CADLoader.load
        #endif
    }

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let image = try Self.image(for: request.fileURL)
        let scale = Self.displaySize / CGFloat(max(image.width, image.height))
        let size = CGSize(width: (CGFloat(image.width) * scale).rounded(),
                          height: (CGFloat(image.height) * scale).rounded())
        // Handing Quick Look image data shows it at its pixel size, so draw it at the size we want.
        return QLPreviewReply(contextSize: size, isBitmap: true) { context, _ in
            context.interpolationQuality = .high
            context.draw(image, in: context.boundingBoxOfClipPath)
        }
    }

    static func image(for url: URL) throws -> CGImage {
        var result = try ModelLoader.load(url)
        if url.pathExtension.lowercased() == "3mf", case .image(let data) = result,
           let size = Loader3MF.imageSize(data), max(size.width, size.height) < minimumSharpImage {
            var options = ModelLoader.Options()
            options.preferEmbeddedThumbnail = false
            result = try ModelLoader.load(url, options: options)
        }
        switch result {
        case .image(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ModelError.malformed("embedded image")
            }
            return image
        case .mesh(let mesh):
            var options = RenderOptions()
            options.size = Int(displaySize * 2)
            options.supersample = mesh.triangleCount > 3_000_000 ? 1 : 2
            let rendered = Renderer.render(mesh, options: options)
            guard let provider = CGDataProvider(data: Data(rendered.pixels) as CFData),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: rendered.width, height: rendered.height, bitsPerComponent: 8,
                                      bitsPerPixel: 32, bytesPerRow: rendered.width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true,
                                      intent: .defaultIntent) else {
                throw ModelError.malformed("render")
            }
            return image
        }
    }
}
