import SwiftUI

/// The polygon library. Every shape is the same 120-point polygon sampled at
/// the same angles, so any shape morphs into any other with a plain SwiftUI
/// animation on `DSPolygon`.
public enum DSShape: String, CaseIterable, Sendable {
    case circle, cookie4, cookie6, cookie9, cookie12
    case clover4, clover8, sunny, burst
    case triangle, square, diamond, pentagon, gem
    case pill, oval, flower, puffy

    /// Display name used on the design-system reference sheet.
    public var label: String {
        switch self {
        case .circle: "Circle"
        case .cookie4: "Cookie 4"
        case .cookie6: "Cookie 6"
        case .cookie9: "Cookie 9"
        case .cookie12: "Cookie 12"
        case .clover4: "Clover 4"
        case .clover8: "Clover 8"
        case .sunny: "Sunny"
        case .burst: "Burst"
        case .triangle: "Triangle"
        case .square: "Square"
        case .diamond: "Diamond"
        case .pentagon: "Pentagon"
        case .gem: "Gem"
        case .pill: "Pill"
        case .oval: "Oval"
        case .flower: "Flower"
        case .puffy: "Puffy"
        }
    }

    /// Number of vertices in every shape's outline.
    public static let pointCount = 120

    /// Outline points in the unit square (0...1, y down), `pointCount` of them.
    public var points: [CGPoint] { Self.table[self] ?? [] }

    // MARK: Radius functions (port of the design's angle → radius curves)

    private static let tau = Double.pi * 2

    /// Triangle wave with `n` teeth, peaking at 1.
    private static func tri(_ n: Double, _ t: Double) -> Double {
        let phase = (n * t / tau).truncatingRemainder(dividingBy: 1)
        let d = abs((phase + 1).truncatingRemainder(dividingBy: 1) - 0.5)
        return d > 0.25 ? 0 : 1 - 2 * d
    }

    /// Regular `n`-gon radius at angle `t`, rotated by `rot`.
    private static func poly(_ n: Double, _ rot: Double, _ t: Double) -> Double {
        let s = tau / n
        let a = ((t - rot).truncatingRemainder(dividingBy: s) + s).truncatingRemainder(dividingBy: s) - s / 2
        return cos(Double.pi / n) / cos(a)
    }

    private func radius(at t: Double) -> Double {
        let pi = Double.pi
        switch self {
        case .circle: return 1
        case .cookie4: return 1 - 0.09 * cos(4 * t)
        case .cookie6: return 1 + 0.065 * cos(6 * t)
        case .cookie9: return 1 + 0.05 * cos(9 * t)
        case .cookie12: return 1 + 0.04 * cos(12 * t)
        case .clover4: return 0.62 + 0.38 * pow(abs(cos(2 * t + pi / 2)), 0.55)
        case .clover8: return 0.8 + 0.2 * pow(abs(cos(4 * t)), 0.6)
        case .sunny: return 0.88 + 0.12 * Self.tri(8, t + pi / 2)
        case .burst: return 0.8 + 0.2 * Self.tri(12, t + pi / 2)
        case .triangle: return Self.poly(3, -pi / 2, t)
        case .square: return Self.poly(4, pi / 4, t)
        case .diamond:
            let c = cos(t)
            return Self.poly(4, 0, t) * (1 - 0.18 * c * c)
        case .pentagon: return Self.poly(5, -pi / 2, t)
        case .gem:
            let c = cos(t)
            return Self.poly(6, 0, t) * (1 - 0.12 * c * c)
        case .pill:
            let b = 0.58, h = 0.42
            let c = abs(cos(t))
            let r1 = b / max(abs(sin(t)), 1e-9)
            return r1 * c <= h ? r1 : h * c + (h * h * c * c - h * h + b * b).squareRoot()
        case .oval: return 0.74 / hypot(0.74 * cos(t), sin(t))
        case .flower: return 0.78 + 0.22 * pow(abs(cos(3 * t + pi * 1.5)), 0.7)
        case .puffy: return 0.9 + 0.1 * pow(abs(cos(5 * t)), 0.5)
        }
    }

    /// Half-width of the circular box filter that rounds sharp corners.
    private var smoothing: Int {
        switch self {
        case .circle, .cookie4, .cookie6, .cookie9, .cookie12, .pill, .oval: 0
        case .clover4, .puffy: 10
        case .clover8: 6
        case .sunny: 22
        case .burst: 12
        case .triangle: 52
        case .square: 46
        case .diamond, .gem: 40
        case .pentagon: 44
        case .flower: 14
        }
    }

    private func computePoints() -> [CGPoint] {
        let m = 720
        let n = Self.pointCount
        let raw = (0..<m).map { radius(at: Double($0) * Self.tau / Double(m) - Double.pi / 2) }
        let w = smoothing
        let rs: [Double]
        if w == 0 {
            rs = raw
        } else {
            rs = (0..<m).map { i in
                var s = 0.0
                for j in -w...w { s += raw[(i + j + m) % m] }
                return s / Double(2 * w + 1)
            }
        }
        var xy: [(Double, Double)] = []
        var mx = 0.0
        for i in 0..<n {
            let k = Int((Double(i * m) / Double(n)).rounded()) % m
            let t = Double(k) * Self.tau / Double(m) - Double.pi / 2
            let x = rs[k] * cos(t), y = rs[k] * sin(t)
            mx = max(mx, abs(x), abs(y))
            xy.append((x, y))
        }
        return xy.map { CGPoint(x: 0.5 + 0.5 * $0.0 / mx, y: 0.5 + 0.5 * $0.1 / mx) }
    }

    private static let table: [DSShape: [CGPoint]] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, $0.computePoints()) }
    )
}

// MARK: - Animatable outline

/// A flat `[x0, y0, x1, y1, …]` vector that SwiftUI can interpolate.
public struct DSPointCloud: VectorArithmetic, Equatable, Sendable {
    var values: [Double]

    public init(_ values: [Double]) {
        self.values = values
    }

    public static var zero: DSPointCloud { DSPointCloud([]) }

    private static func combine(
        _ l: DSPointCloud, _ r: DSPointCloud, _ op: (Double, Double) -> Double
    ) -> DSPointCloud {
        let n = max(l.values.count, r.values.count)
        return DSPointCloud((0..<n).map { i in
            op(i < l.values.count ? l.values[i] : 0, i < r.values.count ? r.values[i] : 0)
        })
    }

    public static func + (l: DSPointCloud, r: DSPointCloud) -> DSPointCloud { combine(l, r, +) }
    public static func - (l: DSPointCloud, r: DSPointCloud) -> DSPointCloud { combine(l, r, -) }
    public static func += (l: inout DSPointCloud, r: DSPointCloud) { l = l + r }
    public static func -= (l: inout DSPointCloud, r: DSPointCloud) { l = l - r }

    public mutating func scale(by rhs: Double) {
        for i in values.indices { values[i] *= rhs }
    }

    public var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}

/// Any `DSShape` as a SwiftUI `Shape`. Changing the shape inside an animation
/// morphs the outline.
///
///     Rectangle().fill(c.primary)
///         .clipShape(DSPolygon(liked ? .burst : .circle))
///         .animation(DSMotion.spatialFast, value: liked)
public struct DSPolygon: Shape {
    public var shape: DSShape
    private var cloud: DSPointCloud

    public init(_ shape: DSShape) {
        self.shape = shape
        self.cloud = DSPointCloud(shape.points.flatMap { [Double($0.x), Double($0.y)] })
    }

    public var animatableData: DSPointCloud {
        get { cloud }
        set { cloud = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let v = cloud.values
        guard v.count >= 6 else { return path }
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: rect.minX + v[2 * i] * rect.width, y: rect.minY + v[2 * i + 1] * rect.height)
        }
        path.move(to: point(0))
        for i in 1..<(v.count / 2) { path.addLine(to: point(i)) }
        path.closeSubpath()
        return path
    }
}

public extension DSShape {
    /// Polygons an UP avatar can take. The same creator always gets the same one.
    static let avatarShapes: [DSShape] = [
        .cookie9, .clover4, .sunny, .pentagon, .flower, .gem, .cookie6, .puffy
    ]

    /// Deterministic shape for an id (FNV-1a, not `hashValue`, which is
    /// randomised per launch).
    static func avatar(forID id: String) -> DSShape {
        avatarShapes[Int(DSHash.fnv1a(id) % UInt64(avatarShapes.count))]
    }

    static func avatar(forID id: Int) -> DSShape {
        avatar(forID: String(id))
    }

    /// Loading-indicator loop: burst → cookie 9 → pentagon → pill → sunny → cookie 4 → oval.
    static let loadingLoop: [DSShape] = [.burst, .cookie9, .pentagon, .pill, .sunny, .cookie4, .oval]
}

/// Stable hashing for deterministic art. Swift's `hashValue` is seeded per
/// launch, which would reshuffle every cover and avatar on each run.
enum DSHash {
    /// 64-bit FNV-1a over the UTF-8 bytes.
    static func fnv1a(_ string: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return h
    }
}
