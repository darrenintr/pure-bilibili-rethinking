import Foundation

/// Display formatting shared by every card and list row.
public enum DSFormat {
    /// 12345 → "1.2萬", 123_456_789 → "1.2億", 999 → "999".
    public static func count(_ value: Int) -> String {
        let n = max(value, 0)
        if n >= 100_000_000 { return scaled(n, unit: 100_000_000) + "億" }
        if n >= 10_000 { return scaled(n, unit: 10_000) + "萬" }
        return String(n)
    }

    /// 65 → "1:05", 3725 → "1:02:05". Negative values clamp to zero.
    public static func duration(seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    /// One decimal place via integer math, truncating (never rounding up
    /// across the unit boundary: 99_999 → "9.9", not "10") and dropping ".0".
    private static func scaled(_ n: Int, unit: Int) -> String {
        let tenths = n / (unit / 10)
        return tenths % 10 == 0 ? String(tenths / 10) : "\(tenths / 10).\(tenths % 10)"
    }
}
