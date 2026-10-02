import SwiftUI

/// Shape loading indicator: seven polygons in a loop (burst, cookie 9,
/// pentagon, pill, sunny, cookie 4, oval) while the frame rotates. Replaces
/// every spinner in the app. Reduce Motion: holds the first shape, no loop.
public struct DSLoadingIndicator: View {
    private let size: CGFloat
    private let contained: Bool
    @State private var step = 0
    @State private var turn = 0.0
    @DSPalette private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 48, contained: Bool = false) {
        self.size = size
        self.contained = contained
    }

    public var body: some View {
        ZStack {
            if contained {
                Circle().fill(c.primaryContainer)
            }
            Rectangle()
                .fill(contained ? c.onPrimaryContainer : c.primary)
                .frame(width: size * 0.8, height: size * 0.8)
                .clipShape(DSPolygon(DSShape.loadingLoop[step]))
                .rotationEffect(.degrees(turn))
        }
        .frame(width: size, height: size)
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) { turn = 360 }
            while !Task.isCancelled {
                try? await Task.sleep(for: DSMotion.loaderStep)
                if Task.isCancelled { break }
                withAnimation(DSMotion.spatialFast) { step = (step + 1) % DSShape.loadingLoop.count }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("載入中")
    }
}

/// A highlighted span of the timeline (e.g. a SponsorBlock segment), in 0...1.
public struct DSProgressSegment: Sendable, Hashable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = min(max(start, 0), 1)
        self.end = min(max(end, start), 1)
    }
}

/// Sine wave from the left edge, used for the played part of a wavy track.
struct DSWaveShape: Shape {
    var amplitude: CGFloat
    var phase: CGFloat
    static let wavelength: CGFloat = 16

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(amplitude, phase) }
        set { amplitude = newValue.first; phase = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0 else { return path }
        let midY = rect.midY
        let step: CGFloat = 1
        var x: CGFloat = 0
        path.move(to: CGPoint(x: rect.minX, y: midY + amplitude * sin(phase * 2 * .pi / Self.wavelength)))
        while x < rect.width {
            x = min(x + step, rect.width)
            let y = midY + amplitude * sin((x + phase) * 2 * .pi / Self.wavelength)
            path.addLine(to: CGPoint(x: rect.minX + x, y: y))
        }
        return path
    }
}

/// Wavy progress / seek track. The played part is a wave that travels only
/// while playing; paused, it flattens to a straight line. Segments (e.g.
/// SponsorBlock) draw over the remaining track in the tertiary colour.
public struct DSWavyProgress: View {
    private let value: Double
    private let isPlaying: Bool
    private let segments: [DSProgressSegment]
    private let height: CGFloat
    private let accessibilityText: String
    @State private var amplitude: CGFloat
    @DSPalette private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        value: Double,
        isPlaying: Bool = false,
        segments: [DSProgressSegment] = [],
        height: CGFloat = 16,
        accessibilityText: String = "播放進度"
    ) {
        self.value = min(max(value, 0), 1)
        self.isPlaying = isPlaying
        self.segments = segments
        self.height = height
        self.accessibilityText = accessibilityText
        _amplitude = State(initialValue: isPlaying ? height * 0.19 : 0)
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let thumbX = width * value
            let stroke = height * 0.25
            ZStack(alignment: .leading) {
                // Remaining track.
                Capsule()
                    .fill(c.secondaryContainer)
                    .frame(width: max(0, width - thumbX - 6), height: stroke * 0.9)
                    .offset(x: thumbX + 6)
                ForEach(segments, id: \.self) { seg in
                    Capsule()
                        .fill(c.tertiary)
                        .frame(width: max(0, width * (seg.end - seg.start)), height: stroke * 0.9)
                        .offset(x: width * seg.start)
                }
                // Played wave.
                TimelineView(.animation(paused: !isPlaying || reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = CGFloat((t / 0.9).truncatingRemainder(dividingBy: 1)) * DSWaveShape.wavelength
                    DSWaveShape(amplitude: amplitude, phase: phase)
                        .stroke(c.primary, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                        .frame(width: max(0, thumbX), height: height)
                        .clipped()
                }
                // Thumb.
                Capsule()
                    .fill(c.primary)
                    .frame(width: 4, height: height)
                    .offset(x: min(max(thumbX - 2, 0), max(width - 4, 0)))
            }
            .frame(height: height)
        }
        .frame(height: height)
        .onChange(of: isPlaying) { _, playing in
            withAnimation(reduceMotion ? nil : DSMotion.spatialFast) {
                amplitude = playing ? height * 0.19 : 0
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityValue("\(Int((value * 100).rounded()))%")
    }
}
