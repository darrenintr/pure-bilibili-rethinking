import SwiftUI

/// Native SwiftUI recreation of the paladala launch animation:
/// a translucent glass bilibili-TV mark materialises over a pale
/// lavender field with two large glass rings, followed by the
/// lowercase wordmark. Pure shapes + materials, no video assets.
struct SplashView: View {
    /// Called once the outro fade completes so the caller can
    /// remove the splash from the view tree.
    var onFinished: () -> Void = {}

    @State private var logoOpacity = 0.0
    @State private var logoScale = 0.86
    @State private var logoBlur: CGFloat = 18
    @State private var eyesOpacity = 0.0
    @State private var wordmarkOpacity = 0.0
    @State private var wordmarkOffset: CGFloat = 8
    @State private var screenOpacity = 1.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // Pale lavender field
                LinearGradient(
                    colors: [
                        Color(red: 0.93, green: 0.93, blue: 0.99),
                        Color(red: 0.97, green: 0.96, blue: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                // Large glass rings bleeding in from opposite corners
                glassRing(diameter: size * 1.1)
                    .position(x: geo.size.width * 0.98, y: geo.size.height * 0.06)
                glassRing(diameter: size * 1.0)
                    .position(x: geo.size.width * 0.02, y: geo.size.height * 0.94)

                VStack(spacing: size * 0.06) {
                    GlassTVMark(size: size * 0.42, eyesOpacity: eyesOpacity)
                        .opacity(logoOpacity)
                        .scaleEffect(logoScale)
                        .blur(radius: logoBlur)

                    Text("paladala")
                        .font(.system(size: size * 0.075, weight: .regular, design: .default))
                        .foregroundStyle(Color(white: 0.25))
                        .opacity(wordmarkOpacity)
                        .offset(y: wordmarkOffset)
                }
            }
        }
        .opacity(screenOpacity)
        .task {
            withAnimation(.easeOut(duration: 0.55)) {
                logoOpacity = 1
                logoScale = 1
                logoBlur = 0
            }
            try? await Task.sleep(for: .milliseconds(380))
            withAnimation(.easeIn(duration: 0.3)) {
                eyesOpacity = 1
            }
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.easeOut(duration: 0.4)) {
                wordmarkOpacity = 1
                wordmarkOffset = 0
            }
            // Hold so the wordmark is legible, then fade the
            // whole screen out and hand off to the caller.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                screenOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }

    private func glassRing(diameter: CGFloat) -> some View {
        Circle()
            .fill(.white.opacity(0.12))
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.9), .white.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2.5
                    )
            )
            .frame(width: diameter, height: diameter)
            .shadow(color: .white.opacity(0.6), radius: 12)
    }
}

/// The bilibili-TV head drawn entirely with SwiftUI shapes:
/// two antenna capsules, a squircle body with a glassy gradient,
/// specular edge highlights and two vertical eye capsules.
private struct GlassTVMark: View {
    let size: CGFloat
    let eyesOpacity: Double

    var body: some View {
        let w = size
        let h = size * 0.78
        ZStack {
            // Antennae
            HStack(spacing: w * 0.13) {
                antenna.rotationEffect(.degrees(-32), anchor: .bottom)
                antenna.rotationEffect(.degrees(32), anchor: .bottom)
            }
            .offset(y: -h * 0.52)

            // Body
            RoundedRectangle(cornerRadius: h * 0.42, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.75, green: 0.83, blue: 1.0).opacity(0.55),
                            Color(red: 0.83, green: 0.78, blue: 1.0).opacity(0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: h * 0.42, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: h * 0.42, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.95),
                                    .white.opacity(0.25),
                                    Color(red: 0.7, green: 0.75, blue: 1.0).opacity(0.5)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 3
                        )
                )
                // Inner specular highlight along the top edge
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: h * 0.42, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.75), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .padding(6)
                        .frame(height: h * 0.42)
                        .padding(.horizontal, w * 0.06)
                        .padding(.top, 4)
                }
                .frame(width: w, height: h)
                .shadow(color: Color(red: 0.6, green: 0.65, blue: 1.0).opacity(0.35), radius: 18, y: 10)

            // Eyes
            HStack(spacing: w * 0.18) {
                eye
                eye
            }
            .opacity(eyesOpacity)
        }
    }

    private var antenna: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.8, green: 0.86, blue: 1.0).opacity(0.8),
                        .white.opacity(0.5)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
            .frame(width: size * 0.09, height: size * 0.3)
    }

    private var eye: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.55, green: 0.62, blue: 0.95),
                        Color(red: 0.68, green: 0.6, blue: 0.95)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(0.65)
            )
            .frame(width: size * 0.07, height: size * 0.16)
    }
}

#Preview {
    SplashView()
}
