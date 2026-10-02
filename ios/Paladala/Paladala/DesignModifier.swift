import SwiftUI
import DesignSystem

struct PaladalaGlassButtonStyle: ButtonStyle {
    let materialDesign: MaterialDesign
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PaladalaTheme.FontRole.body)
            .foregroundStyle(PaladalaTheme.biliPink)
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.vertical, PaladalaTheme.Spacing.m)
            .background(PaladalaTheme.cardBackground, in: RoundedRectangle.ds(DSRadius.control))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85),
                value: configuration.isPressed
            )
    }
}

/// Spring-bounce press feedback for inline buttons. Heavier scale
/// (0.92) and a springier easing than `PaladalaGlassButtonStyle`,
/// so taps on follow / like / favourite / watch-later targets
/// feel tactile. Compose with `.buttonStyle(.plain)` + your
/// custom chrome — this style only owns the press animation.
///
/// Reduce Motion short-circuits the scale so accessibility users
/// still get the press state through the visual highlight only.
struct PaladalaPressBounceButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85),
                value: configuration.isPressed
            )
    }
}

/// Responsive press feedback for the player action bar.
///
/// Each chip in the player control panel uses this style so the
/// press feedback is consistent across subtitle / danmaku /
/// quality / download / coin.  Three layers, all driven by
/// `configuration.isPressed`:
///
/// 1. A scale dip to 0.93 with a snappy spring (response 0.18)
///    so the button feels alive on touch-down.
/// 2. A subtle highlight that lifts the foreground opacity to
///    1.0 (1.0 → 1.0 is a no-op but acts as the explicit
///    "touched" marker when the chip is normally dimmed because
///    it is disabled or pending).
/// 3. A glow halo around the chip that pulses on press — the
///    radial gradient lives behind the label, animates from
///    0 → 0.45 opacity on press, and uses an asymmetric easing
///    so the press builds tension and the release releases it.
///
/// Use `.buttonStyle(PaladalaActionPillStyle())` from any control
/// that lives inside the player's control panel.
struct PaladalaActionPillStyle: ButtonStyle {
    var accent: Color = PaladalaTheme.biliPink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? accent : Color.clear)
            .offset(
                x: configuration.isPressed ? 2 : 0,
                y: configuration.isPressed ? 2 : 0
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}
/// App-wide hard-edged toggle. Applying this at `RootView` keeps settings,
/// onboarding, SponsorBlock, and diagnostics in one shape language while
/// preserving SwiftUI's Toggle semantics and Dynamic Type label layout.
struct PaladalaStreetToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            guard isEnabled else { return }
            Haptics.selection()
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: PaladalaTheme.Spacing.m) {
                configuration.label
                    .foregroundStyle(PaladalaTheme.ink)
                Spacer(minLength: PaladalaTheme.Spacing.s)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Rectangle()
                        .fill(
                            configuration.isOn
                                ? PaladalaTheme.biliPink
                                : PaladalaTheme.coolGray
                        )
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(width: 18, height: 18)
                        .padding(4)
                }
                .frame(width: 48, height: 28)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.1),
                    value: configuration.isOn
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityValue(configuration.isOn ? "開啟" : "關閉")
    }
}

private struct PaladalaInteractiveGlassModifier<S: InsettableShape>: ViewModifier {
    let design: MaterialDesign
    let shape: S
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        fallback(content)
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(tint ?? PaladalaTheme.paper, in: shape)
            .overlay(
                shape.strokeBorder(
                    PaladalaTheme.ink,
                    lineWidth: PaladalaTheme.borderWidth
                )
            )
            .background {
                shape
                    .fill(PaladalaTheme.ink)
                    .offset(
                        x: PaladalaTheme.hardShadowOffset,
                        y: PaladalaTheme.hardShadowOffset
                    )
            }
    }
}

struct PaladalaGlassContainer<Content: View>: View {
    let materialDesign: MaterialDesign
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
    }
}

struct PaladalaBackdrop: View, Equatable {
    @Environment(\.colorScheme) private var envColorScheme
    /// Test-only override. When `nil`, body uses `envColorScheme`
    /// (production path). When non-nil, body uses the override
    /// (unit-test path via `PaladalaBackdrop.scheme(_:)`).
    private var overrideColorScheme: ColorScheme?

    /// Designated init — production callers use `PaladalaBackdrop()`.
    /// `colorScheme` is only used by tests via the `.scheme(_:)`
    /// factory; the production `@Environment` path ignores it.
    init(colorScheme: ColorScheme? = nil) {
        self.overrideColorScheme = colorScheme
    }

    /// Resolved color scheme. `overrideColorScheme` wins so the
    /// `Equatable` test is deterministic under unit-test conditions
    /// (no `@Environment` injection).
    var colorScheme: ColorScheme {
        overrideColorScheme ?? envColorScheme
    }

    /// Equatable — keyed on the resolved color scheme. PR-A audit #10
    /// relies on this so `RootView.body` re-evaluations are skipped
    /// when the backdrop's color scheme is unchanged.
    ///
    /// PR-C Task 5: marked `nonisolated` so the `==` operator
    /// satisfies the `Equatable` protocol's nonisolated
    /// requirement (Swift 6's strict check rejects a
    /// @MainActor-isolated operator where the protocol asks
    /// for a nonisolated one).  The body wraps the
    /// `colorScheme` access in `MainActor.assumeIsolated`
    /// because the call sites are always on the main thread
    /// (XCTest's `XCTAssertEqual` runs on main; SwiftUI's
    /// diffing for `View` re-evaluation also runs on main).
    nonisolated static func == (lhs: PaladalaBackdrop, rhs: PaladalaBackdrop) -> Bool {
        MainActor.assumeIsolated {
            lhs.colorScheme == rhs.colorScheme
        }
    }

    /// Test seam — returns a backdrop with an explicit `colorScheme`
    /// for the `Equatable` test. Not for production use.
    static func scheme(_ scheme: ColorScheme) -> PaladalaBackdrop {
        PaladalaBackdrop(colorScheme: scheme)
    }

    var body: some View {
        PaladalaTheme.canvas
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Card surface — the standard "panel" applied to feeds, video
    /// cards, profile rows, and AI summary cards (15+ call sites).
    /// Variant-aware:
    /// - `.streetRedesign` → sharp Rectangle, 1.5pt ink border, 4pt
    ///   hard shadow.
    /// - `.iosNative` → continuous `RoundedRectangle(16, .continuous)`,
    ///   no border, no hard shadow.  Fill is overridden to
    ///   `secondarySystemGroupedBackground` so the card pops on the
    ///   page's `systemGroupedBackground` (Apple's standard card
    ///   convention).  All 15 current call sites pass the default
    ///   tint, so the override is safe.
    /// - `.classic` → shape follows theme cornerRadius; border /
    ///   shadow still variant-driven (effectively a no-op for the
    ///   hard shadow since classic has `hardShadowOffset == 0`).
    @ViewBuilder
    func paladalaCardSurface(
        _ design: MaterialDesign,
        cornerRadius: CGFloat = PaladalaTheme.cardRadius,
        tint: Color? = nil,
        stroke: Color? = nil,
        strokeWidth: CGFloat = 0.5
    ) -> some View {
        let shape = RoundedRectangle.ds(cornerRadius)
        self
            .background(tint ?? PaladalaTheme.cardBackground, in: shape)
            .overlay {
                if let stroke {
                    shape.strokeBorder(
                        stroke,
                        lineWidth: strokeWidth
                    )
                }
            }
    }

    @ViewBuilder
    func paladalaPillSurface(
        _ design: MaterialDesign
    ) -> some View {
        self
            .background(PaladalaTheme.cardBackground, in: Capsule())
    }

    /// Force the navigation bar to a Street-style opaque `paper`
    /// background.  iOS Native is a no-op so the system draws its
    /// own default (transparent over content, blur over scroll).
    /// Used by `HomeToolbarGlassModifier` /
    /// `LiveToolbarGlassModifier` / `VideoToolbarGlassModifier` /
    /// `DynamicFeedToolbarGlassModifier` (5 call sites).
    @ViewBuilder
    func paladalaNavBarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        if PaladalaTheme.usesNativeLayout {
            self
        } else {
            self
                .toolbarBackground(PaladalaTheme.paper, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// Force the tab bar to a Street-style opaque `paper`
    /// background.  iOS Native is a no-op (system default tab bar
    /// uses the iOS-tinted blur that auto-promotes to Liquid Glass
    /// on iOS 26+).
    @ViewBuilder
    func paladalaToolbarGlass(_ design: MaterialDesign = .liquidGlass) -> some View {
        if PaladalaTheme.usesNativeLayout {
            self
        } else {
            self
                .toolbarBackground(PaladalaTheme.paper, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }

    /// List chrome — applies the variant-correct list style +
    /// background.  Use on the `List` (or its parent) so the rest
    /// of the app code only has to call one modifier:
    /// - `.streetRedesign` → `.listStyle(.plain)` on the Street
    ///   `canvas` background.  Rows are responsible for their own
    ///   card chrome (via `paladalaStreetPanel`).
    /// - `.iosNative` → `.listStyle(.insetGrouped)` on
    ///   `systemGroupedBackground`.  The system draws the rounded
    ///   section cards and hairline separators, so rows must
    ///   *not* apply their own `paladalaStreetPanel`.
    @ViewBuilder
    func paladalaListChrome() -> some View {
        if PaladalaTheme.usesNativeLayout {
            self
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
                .background(Color(uiColor: .systemGroupedBackground))
        } else {
            self
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .background(PaladalaTheme.canvas)
        }
    }

    /// Per-row chrome — applies the variant-correct row
    /// background + separator visibility.  Use on each row
    /// inside the `List` (after the row content is built).
    /// - `.streetRedesign` → transparent row background, hidden
    ///   separator.  Rows paint their own borders via
    ///   `paladalaStreetPanel`.
    /// - `.iosNative` → no-op.  The system section card and hairline
    ///   separators are visible by default in `.insetGrouped` and
    ///   trying to hide them would defeat the HIG card look.
    @ViewBuilder
    func paladalaListRowChrome() -> some View {
        if PaladalaTheme.usesNativeLayout {
            self
        } else {
            self
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    /// Toggle style that matches the active design variant.
    /// - Street → `PaladalaStreetToggleStyle` (硬邊開關).
    /// - iOS Native → `.switch` (system HIG rounded control).
    ///
    /// We can't return `any ToggleStyle` from a helper because
    /// SwiftUI's `.toggleStyle(_:)` modifier takes a generic
    /// `ToggleStyle` parameter — existential types aren't
    /// substitutable there.  Inlining the `if/else` inside a
    /// `@ViewBuilder` extension lets each branch return the
    /// concrete style type that SwiftUI is happy with.
    @ViewBuilder
    func paladalaToggleStyle() -> some View {
        if PaladalaTheme.activeVariant == .expressive {
            self.toggleStyle(.dsSwitch)
        } else if PaladalaTheme.usesNativeLayout {
            self.toggleStyle(.switch)
        } else {
            self.toggleStyle(PaladalaStreetToggleStyle())
        }
    }

    @ViewBuilder
    func paladalaTabBarBehavior() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func paladalaSelectionChip(
        isSelected: Bool,
        design: MaterialDesign
    ) -> some View {
        if PaladalaTheme.usesNativeLayout {
            // iOS Native: capsule + systemFill background.
            // Selected state uses Color.accentColor (follows the
            // user's iOS tint setting).  SF Pro subheadline, no
            // uppercase — the system visual language.
            self
                .font(PaladalaTheme.IOSNative.subheadline)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isSelected
                        ? Color.accentColor
                        : Color(uiColor: .systemFill)
                )
                .clipShape(Capsule())
        } else {
            // Street Minimal: hard-edged rectangle, mono uppercase
            // label, 1.5pt ink border, paper background.  Brand
            // language of the Street variant.
            self
                .font(PaladalaTheme.FontRole.labelMono)
                .textCase(.uppercase)
                .foregroundStyle(isSelected ? PaladalaTheme.paper : PaladalaTheme.ink)
                .background(isSelected ? PaladalaTheme.ink : PaladalaTheme.paper)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }
        }
    }

    /// Picker-style chip. Tap to set `selection` to `value`. Renders
    /// pink when the value matches, neutral otherwise. Used by the
    /// first-run welcome preferences card for `themeMode` /
    /// `materialDesign` style pickers; also reusable in the settings
    /// screen for the same kind of grouped choices.
    @ViewBuilder
    func paladalaPickerChip<Value: Hashable>(
        selection: Binding<Value>,
        value: Value,
        design: MaterialDesign,
        title: String,
        symbol: String
    ) -> some View {
        let isSelected = selection.wrappedValue == value
        Button {
            Haptics.selection()
            selection.wrappedValue = value
        } label: {
            PaladalaChip(title: title, symbol: symbol, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .paladalaSelectionChip(isSelected: isSelected, design: design)
    }

    /// Toggle-style chip. Tap to flip `isOn`. Renders pink when on,
    /// neutral when off. Used by the welcome preferences card for
    /// the on/off feature flags (danmaku, background audio, iCloud).
    /// `disabled` dims + ignores taps — the iCloud chip is disabled
    /// when the user has no iCloud account signed in.
    @ViewBuilder
    func paladalaToggleChip(
        isOn: Binding<Bool>,
        design: MaterialDesign,
        title: String,
        symbol: String,
        disabled: Bool = false
    ) -> some View {
        Button {
            Haptics.selection()
            isOn.wrappedValue.toggle()
        } label: {
            PaladalaChip(title: title, symbol: symbol, isSelected: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .paladalaSelectionChip(isSelected: isOn.wrappedValue, design: design)
    }

    @ViewBuilder
    func paladalaGlassEffect(
        cornerRadius: CGFloat = PaladalaTheme.cardRadius,
        tint: Color = PaladalaTheme.biliPink.opacity(0.06)
    ) -> some View {
        self.paladalaGlassFallback(cornerRadius: cornerRadius, tint: tint)
    }

    @ViewBuilder
    fileprivate func paladalaGlassFallback(
        cornerRadius: CGFloat,
        tint: Color
    ) -> some View {
        self
            .background(PaladalaTheme.cardBackground, in: RoundedRectangle.ds(cornerRadius))
    }

    func paladalaBackdrop() -> some View {
        self.background {
            PaladalaBackdrop()
        }
    }

    /// Opaque paper presentation background for sheets. Apply to the sheet
    /// content so system presentation chrome cannot reintroduce blur.
    @ViewBuilder
    func paladalaSheetGlass() -> some View {
        self
            .presentationBackground(PaladalaTheme.paper)
            .presentationCornerRadius(DSRadius.sheet)
    }

    /// Street Minimal uses a static skeleton. Besides matching the dry,
    /// print-like direction, this removes one infinite animation and one
    /// GeometryReader/mask stack per visible placeholder cell.
    @ViewBuilder
    func paladalaShimmer(active: Bool = true) -> some View {
        self.opacity(active ? 0.72 : 1)
    }

    /// Card-style panel surface.  Variant-aware:
    /// - `.streetRedesign` → sharp `RoundedRectangle(0, .continuous)`
    ///   (= a Rectangle), 1.5pt ink border, 4pt hard shadow.
    /// - `.iosNative` → continuous `RoundedRectangle(16, .continuous)`,
    ///   no border, no hard shadow.  Apple-system cards rely on
    ///   `secondarySystemGroupedBackground` vs the page's
    ///   `systemGroupedBackground` for definition, not a stroke.
    /// - `.classic` → soft glass; the corner radius follows the theme
    ///   token so a future `cornerStyle` change updates both at once.
    ///
    /// The `fill` argument is the caller's per-screen surface tone.
    /// For iOS Native we override it to
    /// `secondarySystemGroupedBackground` (Apple's card-on-grouped-page
    /// convention) so the rounded shape actually pops against the page
    /// — `paper` (= `systemGroupedBackground` for iOS Native) would
    /// make the card invisible.  All 9 current call sites pass
    /// `paper`; if a future caller wants a custom iOS Native fill,
    /// they can fork this modifier.
    func paladalaStreetPanel(
        fill: Color = PaladalaTheme.paper,
        elevated: Bool = true
    ) -> some View {
        self
            .background(PaladalaTheme.cardBackground, in: RoundedRectangle.ds(DSRadius.control))
    }

    func paladalaSectionHeader() -> some View {
        self
            .font(PaladalaTheme.FontRole.sectionHeader)
            .textCase(.uppercase)
            .foregroundStyle(PaladalaTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Street-style "action pill" press feedback (2pt offset + accent
    /// fill on press).  For iOS Native this is a no-op — the system
    /// default tap feedback (a subtle dim on press) is the HIG
    /// convention, and the Street offset looks broken on a rounded
    /// button.
    ///
    /// Apply from any `Toggle` / `Button` / `Menu` that lives inside
    /// the player's control panel (or any other Street-styled action
    /// row) and the variant switch handles itself.
    @ViewBuilder
    func paladalaActionPill(accent: Color = PaladalaTheme.biliPink) -> some View {
        if PaladalaTheme.usesNativeLayout {
            self
        } else {
            self.buttonStyle(PaladalaActionPillStyle(accent: accent))
        }
    }
}

/// Internal label view used by `paladalaPickerChip` and
/// `paladalaToggleChip`. Centralising the visual treatment here
/// means both chip variants share the same SF Symbol + title
/// rhythm without duplication.
private struct PaladalaChip: View {
    let title: String
    let symbol: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(isSelected ? PaladalaTheme.paper : PaladalaTheme.ink)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 8)
    }
}
