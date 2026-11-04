import AppKit
import QuickLookThumbnailing

// Asks Quick Look for a thumbnail the same way Finder does, and fails unless a real
// thumbnail comes back for every file. Unlike `qlmanage -t`, this has a time limit and
// can tell a thumbnail apart from a generic icon.
//
// usage: qlcheck <output folder> <file>...

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: qlcheck <output folder> <file>...")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
var failed = 0

/// False when nothing was drawn, or when everything sits in the bottom-left quarter,
/// which is what drawing at point size into a pixel-sized context looks like.
func fillsCanvas(_ image: CGImage) -> Bool {
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var maxX = -1, minRow = h
    for row in 0..<h {
        for x in 0..<w where pixels[(row * w + x) * 4 + 3] > 8 {
            maxX = max(maxX, x)
            minRow = min(minRow, row)
        }
    }
    return maxX >= 0 && (maxX > w * 55 / 100 || minRow < h * 45 / 100)
}

for path in args[2...] {
    let url = URL(fileURLWithPath: path)
    // Scale 2 is what Finder asks for on a Retina display.
    let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 256, height: 256), scale: 2,
                                               representationTypes: .thumbnail)
    let done = DispatchSemaphore(value: 0)
    var line = "FAIL  \(url.lastPathComponent): timed out"
    var ok = false
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
        if let rep = rep, rep.type == .thumbnail {
            let dest = outDir.appendingPathComponent(url.lastPathComponent + ".ql.png")
            let bitmap = NSBitmapImageRep(cgImage: rep.cgImage)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: dest)
            let size = "\(rep.cgImage.width)x\(rep.cgImage.height)"
            if fillsCanvas(rep.cgImage) {
                line = "ok    \(url.lastPathComponent): \(size)"
                ok = true
            } else {
                line = "FAIL  \(url.lastPathComponent): \(size), but the image is blank or stuck in the bottom-left corner"
            }
        } else {
            line = "FAIL  \(url.lastPathComponent): \(error.map { String(describing: $0) } ?? "no thumbnail")"
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 30)
    print(line.prefix(160))
    if !ok { failed += 1 }
}
exit(failed == 0 ? 0 : 1)
