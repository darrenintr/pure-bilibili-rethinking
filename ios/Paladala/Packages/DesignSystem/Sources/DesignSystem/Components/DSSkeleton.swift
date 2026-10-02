import SwiftUI

/// Shimmering placeholder block. Honors Reduce Motion by staying static.
public struct DSSkeleton: View {
    private let radius: CGFloat
    @State private var phase: CGFloat = -1
    @DSPalette private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(radius: CGFloat = DSRadius.chip) {
        self.radius = radius
    }

    public var body: some View {
        RoundedRectangle.ds(radius)
            .fill(c.surfaceHighest)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, c.surfaceBright.opacity(0.55), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                    }
                    .clipShape(RoundedRectangle.ds(radius))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(DSMotion.shimmer) { phase = 1 }
            }
            .accessibilityHidden(true)
    }
}

/// Skeleton shaped like `DSVideoCard`.
public struct DSVideoCardSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.s) {
            DSSkeleton(radius: DSRadius.card)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            DSSkeleton().frame(height: 14)
            DSSkeleton().frame(width: 90, height: 12)
        }
    }
}
