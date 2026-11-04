import Foundation

/// A flat triangle soup (or point cloud) in a Z-up coordinate system.
public struct Mesh {
    /// x,y,z triples
    public var positions: [Float] = []
    /// vertex indices, three per triangle. Empty for point clouds.
    public var indices: [UInt32] = []
    /// Optional colours, each 0...1. Empty means the renderer's default colour.
    public var palette: [(Float, Float, Float)] = []
    /// Index into `palette` for each triangle. Empty, or one entry per triangle.
    public var triangleColors: [UInt8] = []

    public init() {}

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { positions.isEmpty }

    @inline(__always)
    public mutating func addVertex(_ x: Float, _ y: Float, _ z: Float) {
        positions.append(x); positions.append(y); positions.append(z)
    }

    @inline(__always)
    public mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        indices.append(a); indices.append(b); indices.append(c)
    }

    /// Appends another mesh, applying an optional affine transform.
    public mutating func append(_ other: Mesh, transform: Transform = .identity) {
        let base = UInt32(vertexCount)
        positions.reserveCapacity(positions.count + other.positions.count)
        var i = 0
        let p = other.positions
        while i + 2 < p.count {
            let (x, y, z) = transform.apply(p[i], p[i + 1], p[i + 2])
            positions.append(x); positions.append(y); positions.append(z)
            i += 3
        }
        indices.reserveCapacity(indices.count + other.indices.count)
        for idx in other.indices { indices.append(idx + base) }
    }

    /// Converts a Y-up mesh (OBJ, glTF) to Z-up.
    public mutating func convertYUpToZUp() {
        var i = 0
        while i + 2 < positions.count {
            let y = positions[i + 1], z = positions[i + 2]
            positions[i + 1] = -z
            positions[i + 2] = y
            i += 3
        }
    }

    /// Drops triangles that reference out-of-range vertices.
    public mutating func sanitize() {
        let n = UInt32(vertexCount)
        var bad = false
        for idx in indices where idx >= n { bad = true; break }
        if !bad { return }
        var clean: [UInt32] = []
        clean.reserveCapacity(indices.count)
        let hasColors = triangleColors.count == indices.count / 3
        var cleanColors: [UInt8] = []
        var t = 0
        while t + 2 < indices.count {
            let a = indices[t], b = indices[t + 1], c = indices[t + 2]
            if a < n && b < n && c < n {
                clean.append(a); clean.append(b); clean.append(c)
                if hasColors { cleanColors.append(triangleColors[t / 3]) }
            }
            t += 3
        }
        indices = clean
        triangleColors = cleanColors
    }
}

/// Row-vector affine transform: p' = p * M (3MF convention), stored as 12 numbers
/// m00 m01 m02 / m10 m11 m12 / m20 m21 m22 / m30 m31 m32
public struct Transform {
    public var m: [Float]

    public static let identity = Transform(m: [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])

    public init(m: [Float]) { self.m = m }

    @inline(__always)
    public func apply(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
        (x * m[0] + y * m[3] + z * m[6] + m[9],
         x * m[1] + y * m[4] + z * m[7] + m[10],
         x * m[2] + y * m[5] + z * m[8] + m[11])
    }

    /// Returns the transform that applies `self` first, then `other`.
    public func then(_ other: Transform) -> Transform {
        let a = m, b = other.m
        var r = [Float](repeating: 0, count: 12)
        for row in 0..<3 {
            for col in 0..<3 {
                r[row * 3 + col] = a[row * 3] * b[col] + a[row * 3 + 1] * b[3 + col] + a[row * 3 + 2] * b[6 + col]
            }
        }
        for col in 0..<3 {
            r[9 + col] = a[9] * b[col] + a[10] * b[3 + col] + a[11] * b[6 + col] + b[9 + col]
        }
        return Transform(m: r)
    }

    public var isIdentity: Bool { m == Transform.identity.m }

    /// Builds from a column-major 4x4 matrix (glTF convention, p' = M * p).
    public static func fromColumnMajor4x4(_ c: [Double]) -> Transform {
        guard c.count == 16 else { return .identity }
        // p' = M p with column-major c: x' = c0 x + c4 y + c8 z + c12
        // In row-vector form: m00=c0 m01=c1 m02=c2 (x contributes c0,c1,c2 to x',y',z')
        return Transform(m: [Float(c[0]), Float(c[1]), Float(c[2]),
                             Float(c[4]), Float(c[5]), Float(c[6]),
                             Float(c[8]), Float(c[9]), Float(c[10]),
                             Float(c[12]), Float(c[13]), Float(c[14])])
    }

    /// Builds from glTF translation / rotation quaternion (x,y,z,w) / scale.
    public static func fromTRS(t: [Double]?, r: [Double]?, s: [Double]?) -> Transform {
        let tx = t?.count == 3 ? t![0] : 0, ty = t?.count == 3 ? t![1] : 0, tz = t?.count == 3 ? t![2] : 0
        let sx = s?.count == 3 ? s![0] : 1, sy = s?.count == 3 ? s![1] : 1, sz = s?.count == 3 ? s![2] : 1
        var qx = 0.0, qy = 0.0, qz = 0.0, qw = 1.0
        if let r = r, r.count == 4 { qx = r[0]; qy = r[1]; qz = r[2]; qw = r[3] }
        // Rotation matrix R (column-vector convention)
        let r00 = 1 - 2 * (qy * qy + qz * qz), r01 = 2 * (qx * qy - qz * qw), r02 = 2 * (qx * qz + qy * qw)
        let r10 = 2 * (qx * qy + qz * qw), r11 = 1 - 2 * (qx * qx + qz * qz), r12 = 2 * (qy * qz - qx * qw)
        let r20 = 2 * (qx * qz - qy * qw), r21 = 2 * (qy * qz + qx * qw), r22 = 1 - 2 * (qx * qx + qy * qy)
        // M = T * R * S ; column j of R*S = R col j * s_j
        let col: [Double] = [r00 * sx, r10 * sx, r20 * sx, 0,
                             r01 * sy, r11 * sy, r21 * sy, 0,
                             r02 * sz, r12 * sz, r22 * sz, 0,
                             tx, ty, tz, 1]
        return fromColumnMajor4x4(col)
    }
}

public enum ModelError: Error, CustomStringConvertible {
    case unsupported(String)
    case malformed(String)
    case empty

    public var description: String {
        switch self {
        case .unsupported(let s): return "unsupported: \(s)"
        case .malformed(let s): return "malformed: \(s)"
        case .empty: return "no geometry found"
        }
    }
}

/// What a loader produced: either geometry to render, or a ready-made image (PNG/JPEG bytes).
public enum LoadResult {
    case mesh(Mesh)
    case image(Data)
}
