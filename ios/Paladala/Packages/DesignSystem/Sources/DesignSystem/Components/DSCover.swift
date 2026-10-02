import SwiftUI

/// Generated cover art for a video whose image has not loaded (or has none).
/// The palette comes from the seed, so a feed of unloaded covers is already
/// colourful and the same video always gets the same art.
public struct DSCoverPlaceholder: View {
    private let hue: Double
    private let variant: Int
    private let ambient: Bool
    @State private var spin = 0.0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let arrangements: [[DSShape]] = [
        [.cookie12, .pill, .burst], [.clover4, .oval, .sunny], [.pentagon, .cookie9, .clover8],
        [.flower, .gem, .burst], [.cookie6, .triangle, .sunny], [.sunny, .pill, .cookie4]
    ]

    /// - Parameters:
    ///   - seed: Any stable string (the bvid works).
    ///   - ambient: Slowly rotates the small accent shape. Use for at most one cover per screen.
    public init(seed: String, ambient: Bool = false) {
        let h = DSHash.fnv1a(seed)
        self.hue = Double(h % 360)
        self.variant = Int((h / 360) % UInt64(Self.arrangements.count))
        self.ambient = ambient
    }

    public init(seed: Int, ambient: Bool = false) {
        self.init(seed: String(seed), ambient: ambient)
    }

    public var body: some View {
        let dark = colorScheme == .dark
        let shapes = Self.arrangements[variant]
        let mirrored = variant % 2 == 1
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .topLeading) {
                Color(DSColorEngine.tone(hue: hue, chroma: 30, tone: dark ? 26 : 86))
                part(shapes[0], left: 58, top: -24, size: 56, mirrored: mirrored, w: w, h: h,
                     color: DSColorEngine.tone(hue: hue, chroma: 48, tone: dark ? 52 : 68))
                part(shapes[1], left: 8, top: 50, size: 32, mirrored: mirrored, w: w, h: h,
                     color: DSColorEngine.tone(hue: hue + 40, chroma: 60, tone: dark ? 78 : 42))
                part(shapes[2], left: 42, top: 14, size: 15, mirrored: mirrored, w: w, h: h,
                     color: DSColorEngine.tone(hue: hue - 30, chroma: 20, tone: dark ? 92 : 97),
                     rotation: spin)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
        }
        .onAppear {
            guard ambient, !reduceMotion else { return }
            withAnimation(DSMotion.ambientSpin) { spin = 360 }
        }
        .accessibilityHidden(true)
    }

    private func part(
        _ shape: DSShape, left: CGFloat, top: CGFloat, size: CGFloat, mirrored: Bool,
        w: CGFloat, h: CGFloat, color: DSRGB, rotation: Double = 0
    ) -> some View {
        let l = mirrored ? 100 - left - size : left
        return Rectangle()
            .fill(Color(color))
            .frame(width: size / 100 * w, height: size / 100 * w)
            .clipShape(DSPolygon(shape))
            .rotationEffect(.degrees(rotation))
            .offset(x: l / 100 * w, y: top / 100 * h)
    }
}
