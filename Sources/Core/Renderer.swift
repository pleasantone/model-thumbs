import Foundation

/// CPU renderer: orthographic 3/4 view, z-buffer, two-light shading,
/// supersampled anti-aliasing and a soft silhouette outline. Output is
/// premultiplied RGBA8 with a transparent background.
public struct RenderOptions {
    public var size: Int = 512
    public var supersample: Int = 2
    /// base colour (linear-ish 0...1)
    public var color: (Float, Float, Float) = (0.56, 0.66, 0.78)
    /// camera azimuth / elevation in degrees (0 az = looking from -Y "front")
    public var azimuth: Float = 35
    public var elevation: Float = 28
    public var padding: Float = 0.06
    public var outline: Bool = true
    /// Use the colours stored in the mesh when it has them, instead of `color`.
    public var useMeshColors: Bool = true
    public init() {}
}

public struct Image {
    public let width: Int
    public let height: Int
    /// premultiplied RGBA8
    public var pixels: [UInt8]
}

public enum Renderer {
    public static func render(_ mesh: Mesh, options o: RenderOptions = RenderOptions()) -> Image {
        let ss = max(1, o.supersample)
        let N = o.size * ss
        let pos = mesh.positions
        let vcount = mesh.vertexCount

        // Camera basis
        let az = o.azimuth * .pi / 180, el = o.elevation * .pi / 180
        // direction from target towards camera
        let dx = cos(el) * sin(az), dy = -cos(el) * cos(az), dz = sin(el)
        // right = normalize(cross(forward, Z)), forward = -d
        var rx = -dy, ry = dx // cross((-dx,-dy,-dz),(0,0,1)) = (-dy, dx, 0)
        let rl = (rx * rx + ry * ry).squareRoot()
        rx /= rl; ry /= rl
        // up = cross(right, forward)
        let ux = ry * -dz - 0 * -dy
        let uy = 0 * -dx - rx * -dz
        let uz = rx * -dy - ry * -dx

        // Project all vertices: screen-space x, y, depth (bigger = closer)
        var sx = [Float](repeating: 0, count: vcount)
        var sy = [Float](repeating: 0, count: vcount)
        var sz = [Float](repeating: 0, count: vcount)
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude

        // Only consider referenced vertices for framing (some files carry stray verts)
        var used = [Bool](repeating: mesh.indices.isEmpty, count: vcount)
        if !mesh.indices.isEmpty { for i in mesh.indices { used[Int(i)] = true } }

        pos.withUnsafeBufferPointer { p in
            for i in 0..<vcount {
                let x = p[i * 3], y = p[i * 3 + 1], z = p[i * 3 + 2]
                guard x.isFinite && y.isFinite && z.isFinite else { used[i] = false; continue }
                let a = x * rx + y * ry
                let b = x * ux + y * uy + z * uz
                let c = x * dx + y * dy + z * dz
                sx[i] = a; sy[i] = b; sz[i] = c
                if used[i] {
                    minX = min(minX, a); maxX = max(maxX, a)
                    minY = min(minY, b); maxY = max(maxY, b)
                    minZ = min(minZ, c); maxZ = max(maxZ, c)
                }
            }
        }
        guard maxX >= minX else { return Image(width: o.size, height: o.size, pixels: [UInt8](repeating: 0, count: o.size * o.size * 4)) }

        let spanX = max(maxX - minX, 1e-9), spanY = max(maxY - minY, 1e-9)
        let avail = Float(N) * (1 - 2 * o.padding)
        let scale = avail / max(spanX, spanY)
        let offX = (Float(N) - spanX * scale) / 2 - minX * scale
        let offY = (Float(N) - spanY * scale) / 2 + maxY * scale  // flip Y (screen down)
        for i in 0..<vcount {
            sx[i] = sx[i] * scale + offX
            sy[i] = offY - sy[i] * scale
        }

        // Buffers
        let pixelCount = N * N
        var depth = [Float](repeating: -Float.greatestFiniteMagnitude, count: pixelCount)
        var shade = [Float](repeating: 0, count: pixelCount)  // brightness 0...~1.3
        // Palette index per pixel, only when every triangle has a valid colour.
        let triangleColors = mesh.triangleColors
        let palette = mesh.palette
        let usesColors = o.useMeshColors && !mesh.indices.isEmpty && triangleColors.count == mesh.triangleCount
            && (triangleColors.max().map { Int($0) < palette.count } ?? false)
        var pixelColor = [UInt8](repeating: 0, count: usesColors ? pixelCount : 0)

        // Lights (in world space, derived from camera so lighting is view-relative)
        func norm(_ v: (Float, Float, Float)) -> (Float, Float, Float) {
            let l = max((v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot(), 1e-12)
            return (v.0 / l, v.1 / l, v.2 / l)
        }
        // key: upper-left-front of camera; fill: right; rim from behind-top
        let key = norm((dx * 0.8 - rx * 0.5 + ux * 0.6, dy * 0.8 - ry * 0.5 + uy * 0.6, dz * 0.8 + uz * 0.6))
        let fill = norm((dx * 0.6 + rx * 0.7 - ux * 0.1, dy * 0.6 + ry * 0.7 - uy * 0.1, dz * 0.6 - uz * 0.1))
        let half = norm((key.0 + dx, key.1 + dy, key.2 + dz))

        if mesh.indices.isEmpty {
            // Point cloud: square splats, depth-cued
            let r = max(1, Int((Float(N) / 420).rounded()))
            let zspan = max(maxZ - minZ, 1e-9)
            for i in 0..<vcount where used[i] {
                let cx = Int(sx[i]), cy = Int(sy[i])
                let z = sz[i]
                let s = 0.55 + 0.6 * (z - minZ) / zspan
                for yy in max(0, cy - r)...min(N - 1, cy + r) {
                    for xx in max(0, cx - r)...min(N - 1, cx + r) {
                        let k = yy * N + xx
                        if z > depth[k] { depth[k] = z; shade[k] = s }
                    }
                }
            }
        } else {
            let idx = mesh.indices
            idx.withUnsafeBufferPointer { ip in
            pos.withUnsafeBufferPointer { p in
            depth.withUnsafeMutableBufferPointer { db in
            shade.withUnsafeMutableBufferPointer { sb in
                var t = 0
                let tc = ip.count
                while t + 2 < tc {
                    let ia = Int(ip[t]), ib = Int(ip[t + 1]), ic = Int(ip[t + 2])
                    let triangleColor: UInt8 = usesColors ? triangleColors[t / 3] : 0
                    t += 3
                    // Face normal in world space
                    let ax = p[ia * 3], ay = p[ia * 3 + 1], azz = p[ia * 3 + 2]
                    let e1x = p[ib * 3] - ax, e1y = p[ib * 3 + 1] - ay, e1z = p[ib * 3 + 2] - azz
                    let e2x = p[ic * 3] - ax, e2y = p[ic * 3 + 1] - ay, e2z = p[ic * 3 + 2] - azz
                    var nx = e1y * e2z - e1z * e2y
                    var ny = e1z * e2x - e1x * e2z
                    var nz = e1x * e2y - e1y * e2x
                    let nl = (nx * nx + ny * ny + nz * nz).squareRoot()
                    guard nl > 0, nl.isFinite else { continue }
                    nx /= nl; ny /= nl; nz /= nl
                    // Two-sided: face the camera
                    if nx * dx + ny * dy + nz * dz < 0 { nx = -nx; ny = -ny; nz = -nz }
                    let dk = max(0, nx * key.0 + ny * key.1 + nz * key.2)
                    let df = max(0, nx * fill.0 + ny * fill.1 + nz * fill.2)
                    let sp = max(0, nx * half.0 + ny * half.1 + nz * half.2)
                    let sp2 = sp * sp, sp4 = sp2 * sp2, sp16 = sp4 * sp4 * sp4 * sp4
                    // gentle top lighting (sky) so up-facing surfaces read
                    let sky = 0.5 + 0.5 * nz
                    let brightness = 0.22 + 0.62 * dk + 0.22 * df + 0.10 * sky + 0.18 * sp16

                    // Screen triangle
                    let x0 = sx[ia], y0 = sy[ia], z0 = sz[ia]
                    let x1 = sx[ib], y1 = sy[ib], z1 = sz[ib]
                    let x2 = sx[ic], y2 = sy[ic], z2 = sz[ic]
                    let area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
                    if abs(area) < 1e-12 { continue }
                    let minPX = max(0, Int(min(x0, min(x1, x2)).rounded(.down)))
                    let maxPX = min(N - 1, Int(max(x0, max(x1, x2)).rounded(.up)))
                    let minPY = max(0, Int(min(y0, min(y1, y2)).rounded(.down)))
                    let maxPY = min(N - 1, Int(max(y0, max(y1, y2)).rounded(.up)))
                    if minPX > maxPX || minPY > maxPY { continue }
                    let inv = 1 / area
                    // Tiny triangles: splat one pixel at centroid
                    if maxPX - minPX <= 1 && maxPY - minPY <= 1 {
                        let cx = Int((x0 + x1 + x2) / 3), cy = Int((y0 + y1 + y2) / 3)
                        if cx >= 0 && cy >= 0 && cx < N && cy < N {
                            let k = cy * N + cx
                            let z = (z0 + z1 + z2) / 3
                            if z > db[k] {
                                db[k] = z; sb[k] = brightness
                                if usesColors { pixelColor[k] = triangleColor }
                            }
                        }
                        continue
                    }
                    for py in minPY...maxPY {
                        let fy = Float(py) + 0.5
                        let row = py * N
                        for px in minPX...maxPX {
                            let fx = Float(px) + 0.5
                            let w0 = ((x1 - fx) * (y2 - fy) - (x2 - fx) * (y1 - fy)) * inv
                            let w1 = ((x2 - fx) * (y0 - fy) - (x0 - fx) * (y2 - fy)) * inv
                            let w2 = 1 - w0 - w1
                            if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                            let z = w0 * z0 + w1 * z1 + w2 * z2
                            let k = row + px
                            if z > db[k] {
                                db[k] = z; sb[k] = brightness
                                if usesColors { pixelColor[k] = triangleColor }
                            }
                        }
                    }
                }
            }}}}
        }

        // Silhouette / crease outline from depth discontinuities
        let zspan = max(maxZ - minZ, 1e-9)
        var edge = [Float](repeating: 0, count: pixelCount)
        if o.outline {
            let thr = zspan * 0.04
            let empty = -Float.greatestFiniteMagnitude
            let r = max(1, ss / 2)
            for y in 0..<N {
                for x in 0..<N {
                    let k = y * N + x
                    let z = depth[k]
                    guard z != empty else { continue }
                    var e: Float = 0
                    for (ox, oy) in [(r, 0), (-r, 0), (0, r), (0, -r)] {
                        let xx = x + ox, yy = y + oy
                        if xx < 0 || yy < 0 || xx >= N || yy >= N { e = 1; break }
                        let nz = depth[yy * N + xx]
                        if nz == empty { e = 1; break }
                        if z - nz > thr { e = max(e, 0.6) }
                    }
                    edge[k] = e
                }
            }
        }

        // Resolve supersampled buffer to output pixels
        let W = o.size
        var out = [UInt8](repeating: 0, count: W * W * 4)
        let empty = -Float.greatestFiniteMagnitude
        let (cr, cg, cb) = o.color
        let samples = Float(ss * ss)
        for y in 0..<W {
            for x in 0..<W {
                var ar: Float = 0, ag: Float = 0, ab: Float = 0, aa: Float = 0
                for sy2 in 0..<ss {
                    let row = (y * ss + sy2) * N
                    for sx2 in 0..<ss {
                        let k = row + x * ss + sx2
                        guard depth[k] != empty else { continue }
                        var s = shade[k]
                        // subtle depth cue: farther = slightly darker
                        let dz = (depth[k] - minZ) / zspan
                        s *= 0.86 + 0.14 * dz
                        let base = usesColors ? palette[Int(pixelColor[k])] : (cr, cg, cb)
                        var r = min(1, base.0 * s + 0.04 * max(0, s - 1))
                        var g = min(1, base.1 * s + 0.04 * max(0, s - 1))
                        var b = min(1, base.2 * s + 0.04 * max(0, s - 1))
                        let e = edge[k]
                        if e > 0 {
                            let f = 1 - 0.55 * e
                            r *= f; g *= f; b *= f
                        }
                        ar += r; ag += g; ab += b; aa += 1
                    }
                }
                guard aa > 0 else { continue }
                let o4 = (y * W + x) * 4
                // premultiplied: colour sums already weighted by covered samples
                out[o4] = UInt8(max(0, min(255, (ar / samples) * 255 + 0.5)))
                out[o4 + 1] = UInt8(max(0, min(255, (ag / samples) * 255 + 0.5)))
                out[o4 + 2] = UInt8(max(0, min(255, (ab / samples) * 255 + 0.5)))
                out[o4 + 3] = UInt8(max(0, min(255, (aa / samples) * 255 + 0.5)))
            }
        }
        return Image(width: W, height: W, pixels: out)
    }
}
