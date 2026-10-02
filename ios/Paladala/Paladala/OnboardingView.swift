import Foundation
import SwiftUI

struct OnboardingView: View {
    @AppStorage("paladala.didOnboard") private var didOnboard = false
    @State private var currentPage = 0
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pages: [OnboardingPage] = [
        OnboardingPage(title: "為 B 站而生", subtitle: "首頁 · 推薦 · 動態 · 直播，一個 App 走完", symbol: "play.rectangle.on.rectangle.fill", tint: PaladalaTheme.biliPink),
        OnboardingPage(title: "順手就走的播放", subtitle: "看到一半切走，影片縮成小窗繼續放；想看再點開", symbol: "pip.exit", tint: PaladalaTheme.biliPink),
        OnboardingPage.preferences,
        OnboardingPage(title: "登入後更強", subtitle: "同步歷史、收藏、追番和稍後再看", symbol: "person.crop.circle.badge.checkmark", tint: PaladalaTheme.biliPink),
    ]

    var body: some View {
        // The two variants look completely different in the chrome
        // (background, skip, dots, hero icon, CTA).  Forcing them
        // through a single body would mean a lot of `if isNative`
        // gates that obscure both paths.  The shared state lives in
        // `currentPage`; each variant owns its own page content and
        // page indicator.
        if PaladalaTheme.activeVariant == .iosNative {
            OnboardingViewNative(
                currentPage: $currentPage,
                pages: Self.pages
            )
        } else {
            bodyStreet
        }
    }

    private var bodyStreet: some View {
        ZStack(alignment: .topTrailing) {
            OnboardingAnimatedBackground(page: currentPage)

            TabView(selection: $currentPage) {
                ForEach(Array(Self.pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(
                        page: page,
                        showsLoginCTA: index == Self.pages.count - 1,
                        isPreferencesPage: page.kind == .preferences,
                        currentPageBinding: Binding(
                            get: { currentPage },
                            set: { currentPage = $0 }
                        )
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: currentPage
            )

            VStack {
                skipButton
                    .padding(.trailing, 20)
                    .padding(.top, 12)
                Spacer()
                pageDot
                    .padding(.bottom, 32)
            }
        }
    }

    private var skipButton: some View {
        Button {
            didOnboard = true
        } label: {
            Text(currentPage == Self.pages.count - 1 ? "開始" : "跳過")
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(PaladalaTheme.paper)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .background {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(
                            x: PaladalaTheme.hardShadowOffset,
                            y: PaladalaTheme.hardShadowOffset
                        )
                }
        }
        .buttonStyle(PaladalaPressBounceButtonStyle())
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var pageDot: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.pages.count, id: \.self) { i in
                Rectangle()
                    .fill(i == currentPage ? PaladalaTheme.biliPink : Color.primary.opacity(0.2))
                    .frame(width: i == currentPage ? 24 : 8, height: 8)
                    .overlay {
                        Rectangle()
                            .strokeBorder(PaladalaTheme.ink, lineWidth: 1)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: currentPage)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PaladalaTheme.paper)
        .overlay {
            Rectangle()
                .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
        }
    }
}

// MARK: - Animated background

private struct OnboardingAnimatedBackground: View {
    let page: Int

    var body: some View {
        ZStack {
            PaladalaTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("PALADALA // START")
                    Spacer()
                    Text(String(format: "%02d", page + 1))
                }
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.paper)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .frame(height: 34)
                .background(PaladalaTheme.ink)

                Spacer()

                HStack(spacing: 8) {
                    Rectangle()
                        .fill(PaladalaTheme.biliPink)
                        .frame(maxWidth: .infinity)
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(width: 52)
                }
                .frame(height: 8)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.bottom, PaladalaTheme.Spacing.l)
            }
        }
    }
}

// MARK: - Page model

private struct OnboardingPage: Identifiable {
    enum Kind { case marketing, preferences }
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    init(kind: Kind = .marketing, title: String, subtitle: String, symbol: String, tint: Color) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.tint = tint
    }

    static let preferences = OnboardingPage(kind: .preferences, title: "定製你的體驗", subtitle: "挑你想用的功能，其餘保持預設", symbol: "slider.horizontal.3", tint: PaladalaTheme.biliPink)
}

// MARK: - Page view

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let showsLoginCTA: Bool
    let isPreferencesPage: Bool
    let currentPageBinding: Binding<Int>
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appear = false

    var body: some View {
        if isPreferencesPage {
            OnboardingPreferencesPage(currentPage: currentPageBinding)
                .onAppear { appear = true }
        } else {
            marketingBody
                .onAppear {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                        appear = true
                    }
                }
                .onDisappear { appear = false }
        }
    }

    private var marketingBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 60)

            Image(systemName: page.symbol)
                .font(.system(size: 54, weight: .black))
                .foregroundStyle(PaladalaTheme.ink)
                .frame(width: 124, height: 124)
                .background(PaladalaTheme.biliPink)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .background {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(
                            x: PaladalaTheme.hardShadowOffset,
                            y: PaladalaTheme.hardShadowOffset
                        )
                }
                .scaleEffect(appear || reduceMotion ? 1 : 0.86)
                .opacity(appear ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.25).delay(0.1),
                    value: appear
                )

            VStack(alignment: .leading, spacing: 12) {
                Text(page.title)
                    .font(PaladalaTheme.FontRole.displayLarge)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                    .multilineTextAlignment(.leading)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 20)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.12), value: appear)

                Text(page.subtitle)
                    .font(PaladalaTheme.FontRole.body)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .multilineTextAlignment(.leading)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 16)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.18), value: appear)
            }
            .padding(.top, 28)

            if showsLoginCTA {
                Button {
                    Haptics.tap()
                    router.openLogin()
                } label: {
                    Text("立即登入")
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(PaladalaTheme.biliPink)
                        .overlay {
                            Rectangle()
                                .strokeBorder(
                                    PaladalaTheme.ink,
                                    lineWidth: PaladalaTheme.borderWidth
                                )
                        }
                        .background {
                            Rectangle()
                                .fill(PaladalaTheme.ink)
                                .offset(
                                    x: PaladalaTheme.hardShadowOffset,
                                    y: PaladalaTheme.hardShadowOffset
                                )
                        }
                }
                .buttonStyle(PaladalaPressBounceButtonStyle())
                .padding(.top, 24)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 20)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.24), value: appear)
            }

            Spacer()
        }
        .padding(.horizontal, PaladalaTheme.Spacing.xxxl)
    }
}

// MARK: - Preferences

private struct OnboardingPreferencesPage: View {
    @Binding var currentPage: Int
    @AppStorage("paladala.themeMode") private var themeMode = ThemeMode.system
    @AppStorage("paladala.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("paladala.backgroundAudio") private var backgroundAudio = false
    @AppStorage("paladala.iCloudSync") private var iCloudSync = false
    @AppStorage("paladala.didOnboard") private var didOnboard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 36, weight: .black))
                    .foregroundStyle(PaladalaTheme.ink)
                    .frame(width: 76, height: 76)
                    .background(PaladalaTheme.biliPink)
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                    .scaleEffect(appear || reduceMotion ? 1 : 0.86)
                    .opacity(appear ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.1), value: appear)

                Text("定製你的體驗")
                    .font(PaladalaTheme.FontRole.displayMedium)
                    .foregroundStyle(PaladalaTheme.ink)
                    .textCase(.uppercase)
                    .opacity(appear ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.14), value: appear)

                Text("挑你想用的功能，其餘保持預設")
                    .font(PaladalaTheme.FontRole.bodySmall)
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .multilineTextAlignment(.leading)
                    .opacity(appear ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.18), value: appear)
            }
            .padding(.top, 16)
            .padding(.horizontal, PaladalaTheme.Spacing.xxxl)
            .frame(maxWidth: .infinity, alignment: .leading)

            preferencesCard
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 30)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.2), value: appear)

            Spacer()

            ctaStack
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
                .opacity(appear ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.24), value: appear)
        }
        .onAppear { appear = true }
        .padding(.horizontal, 0)
    }

    @ViewBuilder
    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("主題", systemImage: themeIcon(themeMode))
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                HStack(spacing: 8) {
                    ForEach(ThemeMode.allCases) { mode in
                        Button {
                            Haptics.selection()
                            themeMode = mode
                        } label: {
                            Text(mode.title)
                                .font(PaladalaTheme.FontRole.labelMono)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                        .paladalaSelectionChip(
                            isSelected: themeMode == mode,
                            design: .liquidGlass
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("介面設計", systemImage: "square.grid.3x3.square")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                HStack {
                    Text("STREET MINIMAL")
                        .font(PaladalaTheme.FontRole.labelMono)
                    Spacer()
                    Text("01")
                        .font(PaladalaTheme.FontRole.labelMono)
                        .foregroundStyle(PaladalaTheme.paper)
                        .padding(6)
                        .background(PaladalaTheme.ink)
                }
                .padding(10)
                .background(PaladalaTheme.biliPink)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 12) {
                Label("功能開關", systemImage: "switch.2")
                    .font(PaladalaTheme.FontRole.labelMono)
                featureToggle(
                    title: "彈幕",
                    symbol: "text.bubble.fill",
                    isOn: $danmakuEnabled
                )
                featureToggle(
                    title: "後臺音訊",
                    symbol: "speaker.wave.2.fill",
                    isOn: $backgroundAudio
                )
                featureToggle(
                    title: "iCloud 同步",
                    symbol: "icloud.fill",
                    isOn: $iCloudSync,
                    disabled: !ICloudSync.shared.isAvailable
                )
            }
        }
        .padding(PaladalaTheme.Spacing.content)
        .paladalaStreetPanel(fill: PaladalaTheme.paper)
    }

    private func featureToggle(
        title: String,
        symbol: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        Button {
            guard !disabled else { return }
            Haptics.selection()
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.black))
                Text(title)
                    .font(PaladalaTheme.FontRole.labelMono)
                Spacer()
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.body.weight(.black))
            }
            .foregroundStyle(PaladalaTheme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(isOn.wrappedValue ? PaladalaTheme.biliPink : PaladalaTheme.coolGray)
            .overlay {
                Rectangle()
                    .strokeBorder(
                        PaladalaTheme.ink,
                        lineWidth: PaladalaTheme.borderWidth
                    )
            }
        }
        .buttonStyle(PaladalaPressBounceButtonStyle())
        .opacity(disabled ? 0.45 : 1)
        .accessibilityValue(isOn.wrappedValue ? "開啟" : "關閉")
    }

    private func themeIcon(_ mode: ThemeMode) -> String {
        switch mode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    @ViewBuilder
    private var ctaStack: some View {
        VStack(spacing: 10) {
            Button {
                Haptics.tap()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    currentPage += 1
                }
            } label: {
                Text("下一步")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(PaladalaTheme.biliPink)
                    .overlay {
                        Rectangle()
                            .strokeBorder(
                                PaladalaTheme.ink,
                                lineWidth: PaladalaTheme.borderWidth
                            )
                    }
                    .background {
                        Rectangle()
                            .fill(PaladalaTheme.ink)
                            .offset(
                                x: PaladalaTheme.hardShadowOffset,
                                y: PaladalaTheme.hardShadowOffset
                            )
                    }
            }
            .buttonStyle(PaladalaPressBounceButtonStyle())

            Button {
                Haptics.tap()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    didOnboard = true
                }
            } label: {
                Text("跳過，使用預設")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - iOS Native variant
//
// Street's onboarding carries the brand's hard-edged, mono-cap
// visual language into the first-launch experience (uppercase
// titles, hard-bordered hero icons, mono-spaced labels).  The iOS
// Native variant follows HIG instead: SF Pro text styles at the
// standard sizes, largeTitle-style hero icons on a soft
// `systemGroupedBackground` page, and a per-page system-tint CTA
// at the bottom.  The preferences page becomes a 設計風格 picker
// (3 cards) + 功能開關 list of `.switch` toggles.

private struct OnboardingViewNative: View {
    @Binding var currentPage: Int
    let pages: [OnboardingPage]
    @AppStorage("paladala.didOnboard") private var didOnboard = false
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingNativePageView(
                        page: page,
                        isLastPage: index == pages.count - 1,
                        currentPage: $currentPage
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeOut(duration: 0.2), value: currentPage)

            // Top-right "跳過" text button — HIG convention for
            // modal onboarding flows.  Hidden on the last page
            // where the bottom CTA replaces it.
            if currentPage < pages.count - 1 {
                Button {
                    Haptics.tap()
                    didOnboard = true
                } label: {
                    Text("跳過")
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.top, 8)
            }
        }
    }
}

private struct OnboardingNativePageView: View {
    let page: OnboardingPage
    let isLastPage: Bool
    @Binding var currentPage: Int
    @AppStorage("paladala.didOnboard") private var didOnboard = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)

            if page.kind == .preferences {
                // Preferences page renders its own header + content.
                // Marketing pages render the hero + title + subtitle.
                OnboardingNativePreferencesView()
            } else {
                heroIcon

                Text(page.title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 32)
                    .padding(.horizontal, 16)

                Text(page.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 32)

                Spacer()
            }

            ctaButton
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
    }

    private var heroIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(heroGradient)
                .frame(width: 140, height: 140)
            Image(systemName: page.symbol)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    /// Per-page gradient chosen to match the page's icon.  Mirrors
    /// the mockup's pink / purple / green swatches; the .pink and
    /// .purple use the same starting tone as `biliPink` so the
    /// brand still reads through the iOS Native wrapper.
    private var heroGradient: LinearGradient {
        switch page.symbol {
        case "play.rectangle.on.rectangle.fill":
            return LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.42, blue: 0.42),
                    Color(red: 0.77, green: 0.27, blue: 0.41)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case "pip.exit":
            return LinearGradient(
                colors: [
                    Color(red: 0.345, green: 0.337, blue: 0.839),
                    Color(red: 0.686, green: 0.322, blue: 0.871)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case "person.crop.circle.badge.checkmark":
            return LinearGradient(
                colors: [
                    Color(red: 0.204, green: 0.78, blue: 0.349),
                    Color(red: 0.188, green: 0.69, blue: 0.314)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private var ctaButton: some View {
        Button {
            Haptics.tap()
            if isLastPage {
                didOnboard = true
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    currentPage += 1
                }
            }
        } label: {
            Text(isLastPage ? "開始使用" : "繼續")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    Color.accentColor,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
    }
}

private struct OnboardingNativePreferencesView: View {
    @AppStorage("paladala.designVariant") private var designVariantRaw: String = DesignVariant.streetRedesign.rawValue
    @AppStorage("paladala.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("paladala.backgroundAudio") private var backgroundAudio = false
    @AppStorage("paladala.iCloudSync") private var iCloudSync = false

    private var designVariant: DesignVariant {
        DesignVariant(rawValue: designVariantRaw) ?? .streetRedesign
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("挑你喜歡的風格")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text("選擇後可在設定中隨時切換")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            sectionHeader("設計風格")
            VStack(spacing: 8) {
                // Use the filtered user-facing list (excludes
                // `.classic`, which only exists for legacy
                // UserDefaults migration — see
                // `DesignVariant.userFacingCases`).
                ForEach(DesignVariant.userFacingCases) { variant in
                    designCard(variant)
                }
            }
            .padding(.horizontal, 20)

            sectionHeader("功能開關")
            VStack(spacing: 0) {
                toggleRow("彈幕", symbol: "text.bubble.fill", isOn: $danmakuEnabled)
                Divider().padding(.leading, 50)
                toggleRow("後臺音訊", symbol: "speaker.wave.2.fill", isOn: $backgroundAudio)
                Divider().padding(.leading, 50)
                toggleRow(
                    "iCloud 同步",
                    symbol: "icloud.fill",
                    isOn: $iCloudSync,
                    disabled: !ICloudSync.shared.isAvailable
                )
            }
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .padding(.horizontal, 20)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.leading, 24)
    }

    private func designCard(_ variant: DesignVariant) -> some View {
        let isSelected = (variant == designVariant)
        return Button {
            designVariantRaw = variant.rawValue
            // AppStorage update is enough for the picker to
            // re-render, but other views in the app read
            // `PaladalaTheme.activeVariant` directly.  Calling
            // `apply(_:)` keeps the in-memory singleton in sync
            // so the next render of any view sees the new value.
            PaladalaTheme.apply(variant)
            Haptics.selection()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(cardIconColor(variant))
                        .frame(width: 44, height: 44)
                    Image(systemName: cardIconSymbol(variant))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(variant.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(variant.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(uiColor: .separator),
                            lineWidth: 1.5
                        )
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .padding(14)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : .clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func cardIconColor(_ variant: DesignVariant) -> Color {
        switch variant {
        case .streetRedesign: return .black
        case .iosNative: return Color.accentColor
        case .classic: return Color(uiColor: .systemGray)
        }
    }

    private func cardIconSymbol(_ variant: DesignVariant) -> String {
        switch variant {
        case .streetRedesign: return "rectangle"
        case .iosNative: return "globe"
        case .classic: return "circle.grid.cross"
        }
    }

    private func toggleRow(
        _ title: String,
        symbol: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        }
        .toggleStyle(.switch)
        .disabled(disabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(disabled ? 0.45 : 1)
    }
}
