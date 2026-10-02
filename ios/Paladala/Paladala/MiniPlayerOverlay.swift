import AVFoundation
import SwiftUI

/// Floating mini-player shown when the user navigates away from
/// `VideoDetailView`. Renders the live `AVPlayerLayer` (so the user
/// sees the actual video frame, not a static thumbnail), along
/// with play/pause, expand, and close buttons. Pan down > 80pt to
/// dismiss (calls `store.close()`).
///
/// The overlay is anchored to the bottom-trailing of `RootView`,
/// above the tab bar. Its opaque, hard-edged surface keeps playback
/// controls legible without requiring blur or translucent material.
struct MiniPlayerOverlay: View {
    @EnvironmentObject private var store: MiniPlayerStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    /// `true` while the user is dragging the progress bar to
    /// scrub.  Drives the floating time bubble and pauses the
    /// live position update so the bar doesn't fight the finger.
    @State private var isScrubbing: Bool = false
    /// Position (0..1) the user is dragging to.  We don't seek
    /// on every drag frame — the scrubber would feel laggy —
    /// we just preview the position with the bubble, then seek
    /// once on `.onEnded`.
    @State private var scrubFraction: CGFloat = 0

    var body: some View {
        if let video = store.currentVideo,
           let controller = store.controller,
           store.isShowingMiniPlayer {
            HStack(spacing: PaladalaTheme.Spacing.s) {
                AVPlayerThumbnailView(player: controller.player)
                    .frame(width: 104, height: 60)
                    .clipShape(Rectangle())
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }

                VStack(alignment: .leading, spacing: PaladalaTheme.Spacing.xs) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(video.title)
                            .font(PaladalaTheme.FontRole.bodySmall.weight(.bold))
                            .foregroundStyle(PaladalaTheme.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(video.ownerName)
                            .font(PaladalaTheme.FontRole.labelMono)
                            .foregroundStyle(PaladalaTheme.ink.opacity(0.68))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.bottom, 2)

                    ZStack(alignment: .bottomLeading) {
                        progressBar
                    }
                    .animation(.easeOut(duration: 0.14),
                               value: isScrubbing)
                }
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Haptics.selection()
                    store.togglePlayPause()
                } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.black))
                        .foregroundStyle(PaladalaTheme.ink)
                        .frame(width: 36, height: 36)
                        .modifier(MiniPlayerControlSurface(fill: PaladalaTheme.biliPink))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isPlaying ? "Pause" : "Play")

                Button {
                    Haptics.tap()
                    if let video = store.currentVideo {
                        router.openVideo(video)
                    }
                    store.expand()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(PaladalaTheme.ink)
                        .frame(width: 36, height: 36)
                        .modifier(MiniPlayerControlSurface(fill: PaladalaTheme.paper))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand to inline player")

                Button {
                    Haptics.tap()
                    store.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(PaladalaTheme.paper)
                        .frame(width: 36, height: 36)
                        .modifier(MiniPlayerControlSurface(fill: PaladalaTheme.ink))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close mini-player")
            }
            .modifier(MiniPlayerChromeModifier(
                videoTitle: video.title,
                dismissProgress: dismissProgress,
                reduceMotion: reduceMotion,
                miniPlayerSpring: miniPlayerSpring,
                dragOffset: $dragOffset,
                onClose: { store.close() }
            ))
        }
    }

    private var dismissProgress: CGFloat {
        min(1, max(0, dragOffset / 80))
    }

    private var miniPlayerSpring: Animation? {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.4, dampingFraction: 0.85)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let total = store.duration > 0 ? store.duration : 1
            let liveProgress = min(1, store.currentTime / total)
            // While scrubbing, freeze the bar at the finger
            // position; otherwise mirror the controller's
            // `currentTime`.
            let displayProgress = isScrubbing ? Double(scrubFraction) : liveProgress
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(PaladalaTheme.coolGray)
                    .frame(height: 4)
                    .overlay {
                        Rectangle()
                            .strokeBorder(PaladalaTheme.ink, lineWidth: 1)
                    }
                Rectangle()
                    .fill(PaladalaTheme.biliPink)
                    .frame(width: max(0, geo.size.width * displayProgress), height: 4)

                if isScrubbing {
                    // Knob at the finger so the user gets a
                    // physical "I'm holding the playhead" cue.
                    Rectangle()
                        .fill(PaladalaTheme.paper)
                        .frame(width: 10, height: 10)
                        .overlay {
                            Rectangle()
                                .strokeBorder(PaladalaTheme.ink, lineWidth: 1)
                        }
                        .offset(x: max(0, geo.size.width * scrubFraction) - 5)
                }

                scrubBubble(width: geo.size.width)
            }
            // Extend the hit area vertically without making the
            // bar visually thicker.  `contentShape` makes the
            // empty 11pt-above-and-below space receive the drag.
            .contentShape(Rectangle().inset(by: -11))
            .gesture(scrubGesture(width: geo.size.width, total: total))
        }
        // Total visual + hit height: 2pt bar + 11pt padding above
        // and below.  Anchored bottom-aligned so the hit area
        // doesn't push the rest of the overlay up.
        .frame(height: 24, alignment: .bottom)
    }

    /// Drag gesture that converts a horizontal finger position
    /// into a 0..1 fraction, with a preview bubble during the
    /// drag and a single `store.seek(to:)` call on release.
    /// Seeking every frame would make the scrubber feel laggy
    /// (AVPlayer queues seeks, so the playhead lags by hundreds
    /// of ms); previewing locally and committing on release
    /// matches how Music and other native apps behave.
    private func scrubGesture(width: CGFloat, total: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                let fraction = max(0, min(1, value.location.x / width))
                if !isScrubbing {
                    isScrubbing = true
                    Haptics.selection()
                }
                scrubFraction = fraction
            }
            .onEnded { _ in
                let target = Double(scrubFraction) * total
                store.seek(to: target)
                Haptics.tap()
                isScrubbing = false
            }
    }

    /// Floating time bubble shown above the scrub knob.  Appears
    /// only while `isScrubbing` is true.
    @ViewBuilder
    private func scrubBubble(width: CGFloat) -> some View {
        if isScrubbing {
            let total = store.duration > 0 ? store.duration : 1
            let seconds = Double(scrubFraction) * total
            Text(formatTime(seconds))
                .font(PaladalaTheme.FontRole.labelMono.monospacedDigit())
                .foregroundStyle(PaladalaTheme.paper)
                .padding(.horizontal, PaladalaTheme.Spacing.s)
                .padding(.vertical, PaladalaTheme.Spacing.xs)
                .background(PaladalaTheme.ink)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.biliPink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .fixedSize()
                .offset(x: bubbleOffset(width: width), y: -22)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    private func bubbleOffset(width: CGFloat) -> CGFloat {
        let bubbleWidth: CGFloat = 58
        let halfBubble = bubbleWidth / 2
        let playheadX = width * scrubFraction
        return min(max(playheadX - halfBubble, 0), max(0, width - bubbleWidth))
    }

    /// Compact `m:ss` or `h:mm:ss` formatter for the scrub
    /// bubble.  Mirrors the formatter other parts of the app
    /// use so the bubble and the rest of the UI agree on what
    /// "1:23" looks like.
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// Compact square control used by the floating player. The fill is supplied
/// by the caller so play can carry the signal-pink emphasis while secondary
/// actions stay paper/ink. A one-point hard offset keeps the three controls
/// readable without the compositing cost of a blurred shadow.
private struct MiniPlayerControlSurface: ViewModifier {
    let fill: Color

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(x: 2, y: 2)
                    Rectangle()
                        .fill(fill)
                }
            }
            .overlay {
                Rectangle()
                    .strokeBorder(
                        PaladalaTheme.ink,
                        lineWidth: PaladalaTheme.borderWidth
                    )
            }
    }
}

/// Chrome for the floating mini player.  Extracted from
/// `MiniPlayerOverlay.body` into a `ViewModifier` because the
/// post-HStack modifier chain (clipShape → background → overlay
/// → offset → scaleEffect → opacity → gesture → transition →
/// accessibility × 2) crosses Swift's 50-deep modifier type-check
/// budget and trips the "the compiler is unable to type-check
/// this expression in reasonable time" error.  Wrapping the
/// chrome in a single `ViewModifier` keeps the body short and
/// the type-checker happy.
private struct MiniPlayerChromeModifier: ViewModifier {
    let videoTitle: String
    let dismissProgress: CGFloat
    let reduceMotion: Bool
    let miniPlayerSpring: Animation?
    @Binding var dragOffset: CGFloat
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .frame(width: 34, height: 3)
                    .offset(y: 4)
                    .opacity(Double(dismissProgress))
                    .accessibilityHidden(true)
            }
            .padding(PaladalaTheme.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 88)
            // iOS Native uses a 20pt continuous corner so the Liquid
            // Glass surface reads as a floating card; Street stays
            // on 0pt (a no-op) because the chrome is hard-edged.
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PaladalaTheme.usesNativeLayout ? 20 : 0,
                    style: .continuous
                )
            )
            .background { chromeBackground }
            .overlay {
                // iOS Native: no border, the Liquid Glass edge is the
                // chrome.  Street: 1.5pt ink stroke for the hard-edged
                // Street Minimal look.
                if PaladalaTheme.activeVariant != .iosNative {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
            }
            .offset(y: max(0, dragOffset))
            .scaleEffect(reduceMotion ? 1.0 : 1.0 - (dismissProgress * 0.035), anchor: .bottom)
            .opacity(Double(1.0 - (dismissProgress * 0.18)))
            .gesture(
                DragGesture()
                    .onChanged { dragOffset = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 80 {
                            Haptics.tap()
                            onClose()
                        }
                        withAnimation(miniPlayerSpring) {
                            dragOffset = 0
                        }
                    }
            )
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mini player for \(videoTitle)")
    }

    /// Variant-aware background.  iOS Native → system `.regularMaterial`,
    /// which on iOS 26+ auto-promotes to Liquid Glass and on iOS 18-25
    /// renders as the standard translucent material.  The deployment
    /// target is iOS 18 (see `IPHONEOS_DEPLOYMENT_TARGET` in
    /// `project.pbxproj`), so we can't use the iOS 26-only
    /// `.glassEffect(_:)` modifier here — the Xcode 16 SDK doesn't
    /// expose it.  Street → paper fill + 4pt ink hard shadow.
    @ViewBuilder
    private var chromeBackground: some View {
        if PaladalaTheme.usesNativeLayout {
            Color.clear
                .background(.regularMaterial)
        } else {
            ZStack {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .offset(
                        x: PaladalaTheme.hardShadowOffset,
                        y: PaladalaTheme.hardShadowOffset
                    )
                Rectangle()
                    .fill(PaladalaTheme.paper)
            }
        }
    }
}

/// `UIViewRepresentable` that hosts an `AVPlayerLayer` for the
/// mini-player's video frame. The custom `UIView` overrides
/// `+layerClass` so the layer is an `AVPlayerLayer` — that's the
/// cheapest way to get a real video surface inside a SwiftUI
/// overlay without wrapping the whole `AVPlayerViewController`.
private struct AVPlayerThumbnailView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
        }
    }
}
