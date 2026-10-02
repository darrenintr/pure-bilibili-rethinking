import SwiftUI

public enum DSMotion {
    /// Default interactive spring (response 0.35, damping 0.85).
    public static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    /// Quick state change (press, toggle).
    public static let quick = Animation.easeOut(duration: 0.15)
    /// Skeleton shimmer sweep.
    public static let shimmer = Animation.linear(duration: 1.3).repeatForever(autoreverses: false)
}
