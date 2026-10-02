import SwiftUI
import DesignSystem

/// Legacy persisted values are accepted for decoding, while the app ships one design.
enum DesignVariant: String, CaseIterable, Identifiable, Sendable {
    case classic
    case streetRedesign
    case iosNative
    case expressive

    var id: String { rawValue }

    static func storedChoice(rawValue: String?, migrationVersion: Int) -> DesignVariant {
        .expressive
    }

    /// User-facing label shown in the Settings toggle.
    var title: String {
        switch self {
        case .classic: "經典 Liquid Glass"
        case .streetRedesign: "街頭硬影"
        case .iosNative: "原生 iOS"
        case .expressive: "Paladala Expressive"
        }
    }

    /// Short blurb shown under the toggle so the user knows what
    /// they're getting.
    var blurb: String {
        switch self {
        case .classic:
            "還原到改版前的視覺:圓角 24、玻璃材質、系統色。"
        case .streetRedesign:
            "當前的硬邊極簡風格:無圓角、1.5pt 黑邊、4pt 實心硬影。"
        case .expressive:
            "圓角影片卡、主題色與多邊形動態，支援淺色及深色模式。"
        case .iosNative:
            "純蘋果原生體驗,跟隨系統 tint、SF Pro text style、.searchable 系統搜尋。"
        }
    }

    /// Legacy cases remain decodable, but only Expressive is available.
    static var userFacingCases: [DesignVariant] {
        [.expressive]
    }
}

enum PaladalaTheme {
    // MARK: - Active variant
    //
    // `nonisolated(unsafe)` because every read is a value-typed
    // load (Color / CGFloat / Font — atomic on word-sized
    // copies) and the only writer is the settings toggle on
    // the main actor. Swift 6 strict concurrency refuses plain
    // `static var` outside an actor; this is the documented
    // escape hatch for "I know what I'm doing" globals.
    nonisolated(unsafe) static var activeVariant: DesignVariant = .expressive

    /// Apply a new variant. Called from the Settings toggle and
    /// from `PaladalaApp.init` on launch.
    static func apply(_ variant: DesignVariant) {
        activeVariant = .expressive
    }

    static var usesNativeLayout: Bool { activeVariant == .iosNative || activeVariant == .expressive }
    nonisolated(unsafe) static var expressiveTheme = DSTheme.paladala

    static func expressiveColor(_ role: @escaping @Sendable (DSScheme) -> DSRGB) -> Color {
        let theme = expressiveTheme
        return Color(uiColor: UIColor { traits in
            let rgb = role(traits.userInterfaceStyle == .dark ? theme.dark.scheme : theme.light.scheme)
            return UIColor(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255,
                           blue: Double(rgb.b) / 255, alpha: 1)
        })
    }

    // MARK: - Brand colors (variant-agnostic)
    static var biliPink: Color { activeVariant == .expressive ? expressiveColor { $0.primary } : Color(red: 1.0, green: 0.38, blue: 0.58) } // #FF6194
    static let biliPinkDim = Color(red: 0.70, green: 0.14, blue: 0.35)

    // MARK: - Adaptive ink + paper (variant-aware)
    //
    // The redesign deliberately keeps the palette tiny. `ink` and
    // `paper` invert in dark mode so the same hard-edged hierarchy
    // remains legible without falling back to blur, translucency,
    // or a separate visual language. Pink is a signal color only.
    static var ink: Color {
        if activeVariant == .expressive { return expressiveColor { $0.onSurface } }
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? .white : .black
            })
        case .classic:
            return .primary
        case .iosNative, .expressive:
            // 純蘋果原生：直接用 .primary，0 自定義顏色
            return .primary
        }
    }
    static var paper: Color {
        if activeVariant == .expressive { return expressiveColor { $0.surface } }
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? .black : .white
            })
        case .classic:
            return Color(uiColor: .systemBackground)
        case .iosNative, .expressive:
            // iOS Native 用 systemGroupedBackground 當頁面底色
            return Color(uiColor: .systemGroupedBackground)
        }
    }
    static var canvas: Color {
        if activeVariant == .expressive { return expressiveColor { $0.surface } }
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.045, green: 0.045, blue: 0.045, alpha: 1)
                    : UIColor(red: 0.976, green: 0.976, blue: 0.976, alpha: 1)
            })
        case .classic:
            return Color.clear
        case .iosNative, .expressive:
            return Color(uiColor: .systemGroupedBackground)
        }
    }
    static var coolGray: Color {
        if activeVariant == .expressive { return expressiveColor { $0.surfaceContainer } }
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1)
                    : UIColor(red: 0.957, green: 0.957, blue: 0.957, alpha: 1)
            })
        case .classic:
            return .primary.opacity(0.055)
        case .iosNative, .expressive:
            return Color(uiColor: .secondarySystemGroupedBackground)
        }
    }
    static var mutedInk: Color {
        if activeVariant == .expressive { return expressiveColor { $0.onSurfaceVariant } }
        switch activeVariant {
        case .streetRedesign:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
                    : UIColor(red: 0.30, green: 0.27, blue: 0.27, alpha: 1)
            })
        case .classic:
            return .secondary
        case .iosNative, .expressive:
            return .secondary
        }
    }
    static var cyan: Color {
        if activeVariant == .expressive { return expressiveColor { $0.secondary } }
        switch activeVariant {
        case .streetRedesign: return ink
        case .classic: return Color(red: 0.24, green: 0.78, blue: 0.94)
        case .iosNative, .expressive: return Color.accentColor
        }
    }
    static var violet: Color {
        if activeVariant == .expressive { return expressiveColor { $0.tertiary } }
        switch activeVariant {
        case .streetRedesign: return biliPink
        case .classic: return Color(red: 0.48, green: 0.34, blue: 0.96)
        case .iosNative, .expressive: return Color(uiColor: .systemPurple)
        }
    }

    // MARK: - Geometry (variant-aware)
    static var cornerRadius: CGFloat {
        switch activeVariant {
        case .streetRedesign: return 0
        case .classic: return 24
        case .iosNative: return 16
        case .expressive: return DSRadius.card
        }
    }
    static var cardRadius: CGFloat { cornerRadius }
    static var pillRadius: CGFloat { cornerRadius }
    static var heroRadius: CGFloat { cornerRadius }
    static let cornerStyle: RoundedCornerStyle = .continuous
    static var borderWidth: CGFloat {
        if activeVariant == .expressive { return 0 }
        switch activeVariant {
        case .streetRedesign: return 1.5
        case .classic: return 0
        case .iosNative, .expressive: return 0.5
        }
    }
    static var hairlineWidth: CGFloat {
        switch activeVariant {
        case .streetRedesign: return 1
        case .classic: return 0.5
        case .iosNative, .expressive: return 0.5
        }
    }
    static var hardShadowOffset: CGFloat {
        switch activeVariant {
        case .streetRedesign: return 4
        case .classic: return 0
        case .iosNative, .expressive: return 0
        }
    }
    static var pressedOffset: CGFloat {
        switch activeVariant {
        case .streetRedesign: return 4
        case .classic: return 0
        case .iosNative, .expressive: return 0
        }
    }
    static var pageBackground: Color {
        if activeVariant == .expressive { return expressiveColor { $0.surface } }
        switch activeVariant {
        case .streetRedesign: return canvas
        case .classic: return Color.clear
        case .iosNative, .expressive: return Color(uiColor: .systemGroupedBackground)
        }
    }
    static var cardBackground: Color {
        if activeVariant == .expressive { return expressiveColor { $0.surfaceContainer } }
        switch activeVariant {
        case .streetRedesign: return paper
        case .classic: return Color.primary.opacity(0.055)
        case .iosNative, .expressive: return Color(uiColor: .secondarySystemGroupedBackground)
        }
    }
    static var glassStroke: Color {
        if activeVariant == .expressive { return expressiveColor { $0.outlineVariant } }
        switch activeVariant {
        case .streetRedesign: return ink
        case .classic: return Color.white.opacity(0.24)
        case .iosNative, .expressive: return Color(uiColor: .separator)
        }
    }
    static var glassShadow: Color {
        switch activeVariant {
        case .streetRedesign: return ink
        case .classic: return Color.black.opacity(0.08)
        case .iosNative, .expressive: return .clear
        }
    }

    // MARK: - Spacing scale (xs … xxxl)
    //
    // Use these in place of `.padding(N)` literals so the design
    // language can be tweaked in one place. Picked from the
    // existing distribution (4, 8, 12, 16, 20, 24, 32) so the
    // eventual migration is a 1-to-1 swap.
    enum Spacing {
        /// 4pt — micro gaps (e.g. dot separator from text)
        static let xs: CGFloat = 4
        /// 8pt — small inline gaps (icon ↔ label)
        static let s: CGFloat = 8
        /// 12pt — section-internal gaps (chip to chip)
        static let m: CGFloat = 12
        /// 16pt — content-to-edge padding (the most common)
        static let l: CGFloat = 16
        /// 20pt — generous horizontal padding (login, onboarding hero)
        static let xl: CGFloat = 20
        /// 24pt — between major sections
        static let xxl: CGFloat = 24
        /// 32pt — screen-edge breathing room
        static let xxxl: CGFloat = 32
        /// 48pt — zine-scale separation between editorial blocks.
        /// Falls back to `xxxl` (32) in the classic and iosNative
        /// variants where the editorial spacing layer doesn't exist.
        static var display: CGFloat {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return 48
            case .classic: return xxxl
            case .iosNative, .expressive: return xxxl
            }
        }

        /// Default content padding (alias of `.l`).
        static let content = l
        /// Default section spacing (alias of `.l`).
        static let section = l
    }

    // MARK: - Semantic color tokens
    //
    // Map common iOS system colors to named roles so the design
    // can be retargeted (e.g. for a "true black" dark mode) in
    // one place. Use these instead of `Color(uiColor: …)` in
    // view files.
    enum SemanticColor {
        /// Filled card / surface — main opaque layer.
        static var card: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return paper
            case .classic: return Color(uiColor: .secondarySystemGroupedBackground)
            case .iosNative, .expressive: return Color(uiColor: .secondarySystemGroupedBackground)
            }
        }
        /// Subdued surface — list rows, secondary cards.
        static var surface: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return coolGray
            case .classic: return Color(uiColor: .tertiarySystemGroupedBackground)
            case .iosNative, .expressive: return Color(uiColor: .tertiarySystemGroupedBackground)
            }
        }
        /// Hairline border, chip stroke, divider.
        static var stroke: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return ink
            case .classic: return Color.primary.opacity(0.08)
            case .iosNative, .expressive: return Color(uiColor: .separator)
            }
        }
        /// Primary foreground (text, icon) — adaptive to colorScheme.
        static var onSurface: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return ink
            case .classic: return .primary
            case .iosNative, .expressive: return .primary
            }
        }
        /// Muted foreground (subtitles, captions) — adaptive to colorScheme.
        static var onSurfaceMuted: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return mutedInk
            case .classic: return .secondary
            case .iosNative, .expressive: return .secondary
            }
        }
        /// Accent — brand pink in Street, system accent in iOS Native.
        /// iOS Native 模式下跟隨用戶在 iOS 設置裡選的 tint color（藍、綠、紫、灰都可）。
        static var accent: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return biliPink
            case .classic: return biliPink
            case .iosNative, .expressive: return Color.accentColor
            }
        }
        /// Success (download complete, etc.).
        static var success: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return ink
            case .classic: return .green
            case .iosNative, .expressive: return .green
            }
        }
        /// Warning (rate-limit, slow network).
        static var warning: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return biliPink
            case .classic: return .orange
            case .iosNative, .expressive: return .orange
            }
        }
        /// Error (network failure, parse failure).
        static var error: Color {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return biliPink
            case .classic: return .red
            case .iosNative, .expressive: return .red
            }
        }
    }

    // MARK: - Typography roles
    //
    // Centralised font treatments for repeated roles. Use these
    // instead of `.font(.system(size: …))` for the same conceptual
    // element across multiple screens.
    enum FontRole {
        /// Brand/editorial display face. The system rounded face gives Latin
        /// text a geometric silhouette while preserving complete CJK and
        /// Dynamic Type fallback without shipping multi-megabyte web fonts.
        /// In the classic variant, falls back to `.largeTitle` so callers
        /// that adopt the new role don't crash.
        static var displayLarge: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 36, weight: .black, design: .rounded)
            case .classic: return .largeTitle
            case .iosNative, .expressive: return .largeTitle
            }
        }
        static var displayMedium: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 28, weight: .black, design: .rounded)
            case .classic: return .title
            case .iosNative, .expressive: return .title
            }
        }
        static var headline: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 24, weight: .bold, design: .default)
            case .classic: return .headline
            case .iosNative, .expressive: return .headline
            }
        }
        static var body: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 16, weight: .regular, design: .default)
            case .classic: return .body
            case .iosNative, .expressive: return .body
            }
        }
        static var bodySmall: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 14, weight: .regular, design: .default)
            case .classic: return .callout
            case .iosNative, .expressive: return .callout
            }
        }
        static var labelMono: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 12, weight: .medium, design: .monospaced)
            case .classic: return .caption2
            case .iosNative, .expressive: return .caption2
            }
        }
        /// Card / row title — same weight as a section title but smaller.
        static var cardTitle: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 16, weight: .bold, design: .rounded)
            case .classic: return .headline
            case .iosNative, .expressive: return .headline
            }
        }
        /// Section header in a scroll view — slightly larger.
        static var sectionHeader: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 20, weight: .black, design: .rounded)
            case .classic: return .title3.weight(.semibold)
            case .iosNative, .expressive: return .title3.weight(.semibold)
            }
        }
        /// Large icon for an empty / placeholder state.
        static let emptyStateIcon: Font = .system(size: 56, weight: .light)
        /// Very large hero icon (onboarding).
        static let heroIcon: Font = .system(size: 96, weight: .light)
        /// Live / LIVE badge inside a card.
        static var badge: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return .system(size: 11, weight: .bold, design: .monospaced)
            case .classic: return .caption2.weight(.bold)
            case .iosNative, .expressive: return .caption2.weight(.bold)
            }
        }
        /// Compact monospaced caption (log viewer timestamps).
        static var monospacedCaption: Font {
            switch PaladalaTheme.activeVariant {
            case .streetRedesign: return labelMono
            case .classic: return .system(.caption2, design: .monospaced)
            case .iosNative, .expressive: return .system(.caption2, design: .monospaced)
            }
        }
    }

    // MARK: - iOS Native tokens (集中命名空間)
    //
    // 給 iOS Native 變體用的 token 命名空間，方便組件直接引用而不必
    // 判斷 activeVariant。值都是 iOS 系統色 / 系統字 / 標準圓角，
    // 跟隨系統 theme 與 Dynamic Type。
    //
    // 命名衝突處理：
    // - `ink` / `paper` / `card` 等屬性與上面 `PaladalaTheme` 平級屬性同名，
    //   通過完整路徑 `PaladalaTheme.IOSNative.ink` 訪問避免歧義。
    // - `title` / `headline` / `body` 等跟 `Spacing` 或 `FontRole` 同名但語義不同，
    //   通過 namespace 區分。
    enum IOSNative {
        // MARK: - 顏色（全部系統色，0 自定義）

        /// 主文字 / 圖標 — 自動跟隨 light/dark
        static let ink = Color.primary

        /// 頁面背景 — 跟隨系統分組背景
        static let paper = Color(uiColor: .systemGroupedBackground)

        /// 卡片背景 — 二級分組背景
        static let card = Color(uiColor: .secondarySystemGroupedBackground)

        /// 三級表面（嵌套 chip / 段）
        static let surface = Color(uiColor: .tertiarySystemGroupedBackground)

        /// 0.5pt 分隔線
        static let separator = Color(uiColor: .separator)

        /// 強調色 — 跟隨系統 tint（用戶在 iOS 設置裡改，全 app 跟隨）
        static let tint = Color.accentColor

        /// 填充色（chip 未選中、segmented control 背景）
        static let fill = Color(uiColor: .systemFill)

        // MARK: - 圓角（連續圓角）

        /// 卡片圓角 16pt
        static let cardRadius: CGFloat = 16

        /// Chip 圓角 999 = capsule
        static let chipRadius: CGFloat = 999

        /// 按鈕圓角 10pt
        static let buttonRadius: CGFloat = 10

        /// Hero / 浮卡圓角 24pt
        static let heroRadius: CGFloat = 24

        /// 搜索欄圓角 12pt
        static let searchRadius: CGFloat = 12

        // MARK: - 邊框 / 陰影

        /// hairline 0.5pt
        static let hairline: CGFloat = 0.5

        /// elevation 0 — iOS Native 不用硬陰影，靠 .glassEffect 自身
        static let elevation: CGFloat = 0

        // MARK: - 字體（純 SF Pro text style，0 自定義字體）

        static let largeTitle:  Font = .largeTitle    // 34pt bold
        static let title:       Font = .title         // 28pt regular
        static let title2:      Font = .title2        // 22pt regular
        static let title3:      Font = .title3        // 20pt regular
        static let headline:    Font = .headline      // 17pt semibold
        static let body:        Font = .body          // 17pt regular
        static let callout:     Font = .callout       // 16pt regular
        static let subheadline: Font = .subheadline   // 15pt regular
        static let footnote:    Font = .footnote      // 13pt regular
        static let caption:     Font = .caption       // 12pt regular
        static let caption2:    Font = .caption2      // 11pt regular
    }

    // MARK: - Deprecated aliases
    //
    // Kept for source compatibility during the migration. New
    // code should use `PaladalaTheme.Spacing.content` / `.section`.
    @available(*, deprecated, message: "Use PaladalaTheme.Spacing.content")
    static let contentPadding: CGFloat = 16
    @available(*, deprecated, message: "Use PaladalaTheme.Spacing.section")
    static let sectionSpacing: CGFloat = 16
}

/// User-facing light/dark preference. Stored as a raw string in
/// `@AppStorage` so the value survives app upgrades even if we add new
/// cases. Mapped to SwiftUI's `ColorScheme?` at the root.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    static func storedChoice(rawValue: String?, migrationVersion: Int) -> DesignVariant {
        guard migrationVersion >= 1, let rawValue,
              let variant = DesignVariant(rawValue: rawValue), variant != .classic else {
            return .expressive
        }
        return variant
    }

    var title: String {
        switch self {
        case .system: "跟隨系統"
        case .light: "淺色"
        case .dark: "深色"
        }
    }

    /// The SwiftUI `ColorScheme?` value for `.preferredColorScheme(...)`.
    /// `nil` means "follow the system" (matches the `.system` case).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Glass material used by the per-view glass modifiers
/// (`.paladalaCardSurface`, nav bars, toolbars). Unrelated to
/// the top-level `DesignVariant` — this is a SwiftUI material
/// choice, not a design language.
enum MaterialDesign: String, CaseIterable, Identifiable {
    case material3
    case liquidGlass

    var id: String { rawValue }

    static func storedChoice(rawValue: String?, migrationVersion: Int) -> DesignVariant {
        guard migrationVersion >= 1, let rawValue,
              let variant = DesignVariant(rawValue: rawValue), variant != .classic else {
            return .expressive
        }
        return variant
    }

    var title: String {
        switch self {
        case .material3: "Material 3"
        case .liquidGlass: "Liquid Glass"
        }
    }
}

extension Int {
    var compactCount: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        }
        if self >= 1_000 {
            return String(format: "%.1fK", Double(self) / 1_000)
        }
        return "\(self)"
    }
}

extension Int {
    var mmss: String {
        let minutes = self / 60
        let seconds = self % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension Date {
    /// Compact Chinese relative-time label used on the home
    /// `VideoCard` date row.
    ///
    ///  - "剛剛"  under 1 minute
    ///  - "N 分鐘前"  under 1 hour
    ///  - "N 小時前"  under 24 hours
    ///  - "N 天前"    under 30 days
    ///  - "N 週前"    under 12 months
    ///  - "N 個月前"  under 12 months
    ///  - "N 年前"    older
    ///  - "yyyy-MM-dd"  when the date is more than 1 year in
    ///    the past, or any future date (server clock skew)
    ///
    /// `Locale.current` is used so the Chinese labels stay
    /// natural on the iOS 26 zh-Hans / zh-Hant systems the
    /// build targets; English / Japanese / Korean regions get
    /// the same labels in their script as long as the
    /// surrounding chrome is also localised.
    var relativeDateLabel: String {
        let now = Date()
        let delta = now.timeIntervalSince(self)
        // Future date — server clock skew or a scheduled premiere.
        // Fall back to a calendar string so we don't render
        // "剛剛" for a 2099 timestamp.
        if delta < 0 {
            return absoluteDateLabel
        }
        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        let day: TimeInterval = 24 * hour
        let week: TimeInterval = 7 * day
        let month: TimeInterval = 30 * day
        let year: TimeInterval = 365 * day
        if delta < minute {
            return "剛剛"
        }
        if delta < hour {
            return "\(Int(delta / minute)) 分鐘前"
        }
        if delta < day {
            return "\(Int(delta / hour)) 小時前"
        }
        if delta < week {
            return "\(Int(delta / day)) 天前"
        }
        if delta < month {
            return "\(Int(delta / week)) 週前"
        }
        if delta < year {
            return "\(Int(delta / month)) 個月前"
        }
        return "\(Int(delta / year)) 年前"
    }

    /// `yyyy-MM-dd` short calendar form.  Used for older videos
    /// (over a year ago) and for any future date that the
    /// relative form would mis-render.
    var absoluteDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}
