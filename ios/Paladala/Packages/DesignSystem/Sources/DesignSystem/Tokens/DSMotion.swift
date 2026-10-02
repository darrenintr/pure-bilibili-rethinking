import SwiftUI

/// Motion tokens. Spatial springs move or reshape things and may overshoot;
/// effects springs fade and recolour and never do. Only transform, clip shape,
/// opacity and colour animate.
public enum DSMotion {
    private static func makeSpring(stiffness k: Double, damping ratio: Double) -> Animation {
        .interpolatingSpring(mass: 1, stiffness: k, damping: 2 * ratio * k.squareRoot())
    }

    // Spatial

    /// ζ 0.6 · k 800 · ~350 ms. Shape morphs, like burst, nav indicator, press.
    public static let spatialFast = makeSpring(stiffness: 800, damping: 0.6)
    /// ζ 0.8 · k 380 · ~410 ms. Sheets, cover → player, list reorder.
    public static let spatialDefault = makeSpring(stiffness: 380, damping: 0.8)
    /// ζ 0.8 · k 200 · ~570 ms. Full-screen transitions, hero morphs.
    public static let spatialSlow = makeSpring(stiffness: 200, damping: 0.8)

    // Effects

    /// ζ 1 · k 3800 · ~140 ms. Press states, ripples, icon swaps.
    public static let effectsFast = makeSpring(stiffness: 3800, damping: 1)
    /// ζ 1 · k 1600 · ~210 ms. Colour and opacity crossfades.
    public static let effectsDefault = makeSpring(stiffness: 1600, damping: 1)
    /// ζ 1 · k 800 · ~300 ms. Theme re-seed, skeleton → content.
    public static let effectsSlow = makeSpring(stiffness: 800, damping: 1)

    // Utility

    /// Default interactive spring (response 0.35, damping 0.85).
    public static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    /// Quick state change (press, toggle).
    public static let quick = Animation.easeOut(duration: 0.15)
    /// Skeleton shimmer sweep.
    public static let shimmer = Animation.linear(duration: 1.3).repeatForever(autoreverses: false)

    /// Time between loop steps of the shape loading indicator.
    public static let loaderStep: Duration = .milliseconds(700)
    /// Full turn of the ambient spinning frame.
    public static let ambientSpin = Animation.linear(duration: 14).repeatForever(autoreverses: false)
    /// Delay between staggered children rising in.
    public static let stagger: Duration = .milliseconds(50)
}

private struct DSSpatialAnimation<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Reduce Motion: shapes hold still. Colour crossfades use `dsEffects`.
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

public extension View {
    /// Animates movement / reshaping with a spatial spring, or snaps when
    /// Reduce Motion is on.
    func dsSpatial<V: Equatable>(
        _ animation: Animation = DSMotion.spatialFast, value: V
    ) -> some View {
        modifier(DSSpatialAnimation(animation: animation, value: value))
    }

    /// Animates colour / opacity changes. Still runs under Reduce Motion.
    func dsEffects<V: Equatable>(
        _ animation: Animation = DSMotion.effectsDefault, value: V
    ) -> some View {
        self.animation(animation, value: value)
    }
}
