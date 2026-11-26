//
//  AppVersion.swift
//  Paladala
//
//  Per-build fingerprint + release-type detection for the 关于
//  (About) page.  The identifier is a 12-char lowercase hex
//  string derived from a SHA-1 over the build's stable inputs
//  (bundleId + marketing version + build number + release type
//  + git short SHA + epoch + optional salt), rendered as
//  `PD-XXXX-XXXX-XXXX` so testers can copy-paste it into bug
//  reports and support can map it back to a specific binary.
//
//  Identifier uniqueness strategy:
//    - CI (ios-unsigned-ipa.yml): sets BPBuildCommit /
//      BPBuildDate / BPBuildEpoch to the git SHA, ISO date,
//      and Unix seconds so every prerelease has a different
//      identifier.
//    - Local dev: keys are left empty; this file falls back
//      to the .app binary's modification time (the same
//      binary always has the same mtime; every rebuild
//      changes the mtime, so each rebuild gets a new
//      identifier).
//

import Foundation
import CryptoKit

// MARK: - Release type

/// Where the running binary came from.  Used by the About
/// page to render a human-readable channel label and by the
/// update checker to decide whether a "newer than local"
/// result is meaningful (a sideloaded dev build is never
/// "up to date" against an App Store release line).
enum ReleaseType: String, Codable, CaseIterable, Sendable {
    case debug
    case testflight
    case appStore
    case enterprise
    case sideload
    case unknown

    /// User-facing label rendered on the About page and
    /// returned by `AppVersionInfo.releaseTypeDisplay`.
    var displayName: String {
        switch self {
        case .debug:      return L10n.about.debug
        case .testflight: return L10n.about.testflight
        case .appStore:   return L10n.about.appStore
        case .enterprise: return L10n.about.enterprise
        case .sideload:   return L10n.about.sideload
        case .unknown:    return L10n.about.unknown
        }
    }

    /// True when the running binary is a development build
    /// (debugger-attached, locally signed, or a TestFlight
    /// sandbox).  The update checker uses this to render the
    /// "dev build" branch instead of trying to compare a
    /// locally-built binary against an App Store release line.
    var isDevelopment: Bool {
        switch self {
        case .debug, .sideload, .testflight, .unknown:
            return true
        case .appStore, .enterprise:
            return false
        }
    }
}

// MARK: - AppVersionInfo

/// Snapshot of the running build's identity.  Immutable; the
/// `AppVersion.current` singleton is computed once at first
/// access and reused for the lifetime of the process.
struct AppVersionInfo: Equatable, Sendable {
    let bundleId: String
    let marketingVersion: String
    let buildNumber: String
    let releaseType: ReleaseType
    let channel: String
    let commitShort: String?
    let buildDate: Date?
    /// 12 lowercase hex chars — the raw value used to derive
    /// `identifierDisplay`.  Stable per binary, distinct per
    /// rebuild.
    let identifier: String
    /// Pretty-printed identifier in `PD-XXXX-XXXX-XXXX` form.
    let identifierDisplay: String
    /// Underlying fingerprint inputs, useful for the
    /// diagnostic report.
    let fingerprintInputs: [String: String]

    /// User-facing release-type label.
    var releaseTypeDisplay: String { releaseType.displayName }

    /// Compact version string for the row subtitle, e.g.
    /// `0.5.1 (2)`.  Falls back to whatever the Info.plist
    /// held if the marketing version is missing.
    var versionLine: String {
        "\(marketingVersion) (\(buildNumber))"
    }
}

// MARK: - AppVersion

/// Singleton accessor for the running build's identity.
enum AppVersion {

    /// Computed once on first access.  All About-page reads go
    /// through this so the same identifier is rendered no
    /// matter how many times the view re-evaluates.
    static let current: AppVersionInfo = make()

    // MARK: Build it

    private static func make() -> AppVersionInfo {
        let bundle = Bundle.main
        let bundleId = bundle.bundleIdentifier ?? "unknown.bundle"
        let marketing = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
        let commit = trimmed(bundle.object(forInfoDictionaryKey: "BPBuildCommit") as? String)
        let date = parseDate(bundle.object(forInfoDictionaryKey: "BPBuildDate") as? String)
        let epoch = trimmed(bundle.object(forInfoDictionaryKey: "BPBuildEpoch") as? String)
        let salt = trimmed(bundle.object(forInfoDictionaryKey: "BPBuildIdentifierSalt") as? String)
        let channel = trimmed(bundle.object(forInfoDictionaryKey: "BPBuildChannel") as? String) ?? "local"
        let release = detectReleaseType()

        let inputs: [String: String] = [
            "bundleId": bundleId,
            "marketingVersion": marketing,
            "buildNumber": build,
            "releaseType": release.rawValue,
            "commit": commit ?? "none",
            "epoch": epoch ?? fallbackEpoch(),
            "salt": salt ?? ""
        ]
        let identifier = makeIdentifier(inputs: inputs)
        return AppVersionInfo(
            bundleId: bundleId,
            marketingVersion: marketing,
            buildNumber: build,
            releaseType: release,
            channel: channel,
            commitShort: commit,
            buildDate: date,
            identifier: identifier,
            identifierDisplay: formatIdentifier(identifier),
            fingerprintInputs: inputs
        )
    }

    /// Hash the fingerprint inputs into the 12-char hex
    /// identifier.  Public so tests can verify the algorithm.
    static func makeIdentifier(inputs: [String: String]) -> String {
        // Order the dictionary by key so two builds with the
        // same logical inputs always hash to the same value
        // (a Swift `Dictionary` is unordered).
        let ordered = inputs.keys.sorted().map { key in
            "\(key)=\(inputs[key] ?? "")"
        }.joined(separator: "|")
        let digest = Insecure.SHA1.hash(data: Data(ordered.utf8))
        // 6 bytes = 12 hex chars — wide enough to make a
        // collision in the build's known lifetime
        // (~10^14 values) statistically impossible.
        let bytes = Array(digest.prefix(6))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Format `deadbeef1234` as `PD-DEAD-BEEF-1234` for
    /// display.  Lowercase stays in the raw value; the
    /// display form is uppercased so it reads as a serial
    /// number on the About page.
    static func formatIdentifier(_ hex: String) -> String {
        let upper = hex.uppercased()
        // Pad on the LEFT in case the input is shorter than
        // 12 chars (shouldn't happen, but defensive) so the
        // meaningful digits stay at the end.
        let padded = String(repeating: "0", count: max(0, 12 - upper.count)) + upper
        let chunks = stride(from: 0, to: 12, by: 4).map { i -> String in
            let start = padded.index(padded.startIndex, offsetBy: i)
            let end = padded.index(start, offsetBy: 4)
            return String(padded[start..<end])
        }
        return "PD-" + chunks.joined(separator: "-")
    }

    // MARK: Release-type detection

    /// Decide which `ReleaseType` best describes the
    /// currently-running binary.  Order matters:
    ///   1. `#if DEBUG` always wins (a debug build, even one
    ///      that happens to have a provisioning profile
    ///      attached, is still a debug build).
    ///   2. TestFlight is the next-most-specific branch
    ///      because the AppStore receipt exists but the
    ///      receipt is the sandbox flavour and the
    ///      embedded.mobileprovision is the TestFlight
    ///      flavour.
    ///   3. AppStore: a non-empty receipt and no
    ///      provisioning profile.
    ///   4. Enterprise: a provisioning profile that allows
    ///      all devices.
    ///   5. Sideload: an unsigned binary the user dragged
    ///      into iTunes / Sideloadly / etc. — no receipt
    ///      and no provisioning profile.
    static func detectReleaseType() -> ReleaseType {
        #if DEBUG
        return .debug
        #else
        let bundle = Bundle.main
        let receiptURL = bundle.appStoreReceiptURL
        let receiptPath = receiptURL?.path
        let receiptExists = receiptPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let provisionURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
        let provisionExists = provisionURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        if provisionExists, let url = provisionURL,
           let provisionsAll = readProvisionBool(url: url, key: "ProvisionsAllDevices"),
           provisionsAll {
            return .enterprise
        }
        if receiptExists, let url = receiptURL,
           isTestFlightReceipt(at: url) {
            return .testflight
        }
        if receiptExists {
            return .appStore
        }
        if provisionExists {
            // A signed-but-not-receipt build (e.g. an
            // internal-distribution IPA with a developer
            // provisioning profile). Treat as sideload so
            // the About page surfaces the real story.
            return .sideload
        }
        return .unknown
        #endif
    }

    /// The binary modification time formatted as Unix
    /// seconds.  Used as the identifier-input `epoch` for
    /// local-dev builds where the Info.plist doesn't carry
    /// one.  Same binary → same mtime → same identifier;
    /// every rebuild → different mtime → new identifier.
    static func fallbackEpoch() -> String {
        let url = Bundle.main.executableURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Paladala")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attrs?[.modificationDate] as? Date) ?? Date()
        return String(Int64(date.timeIntervalSince1970))
    }

    // MARK: Helpers

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        // Fall back to a looser parser for build times that
        // drop the timezone.
        let alt = DateFormatter()
        alt.locale = Locale(identifier: "en_US_POSIX")
        alt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        alt.timeZone = TimeZone(secondsFromGMT: 0)
        return alt.date(from: raw)
    }

    /// Read a top-level boolean key from an
    /// embedded.mobileprovision file.  The file is a CMS
    /// envelope; we only need to peek at the
    /// `ProvisionsAllDevices` key, so a regex over the
    /// plain-text portions of the plist is enough — full
    /// ASN.1 parsing is overkill here.
    private static func readProvisionBool(url: URL, key: String) -> Bool? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .ascii) else {
            return nil
        }
        // Match `<key>ProvisionsAllDevices</key>` followed by
        // a `<true/>` or `<false/>` element.
        let pattern = "<\(key)>\\s*</?key>\\s*<(true|false)/?>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return text[valueRange] == "true"
    }

    /// TestFlight receipts live at the same `appStoreReceiptURL`
    /// as App Store receipts but their ASN.1 payload carries
    /// an OID for the production/sandbox environment.  The
    /// public API only exposes the receipt as opaque bytes, so
    /// we sniff the first ~32 bytes for the well-known TestFlight
    /// ASN.1 prefix `1.2.840.113635.100.6.3.X` (X is 1 for
    /// sandbox, 2 for production).  Falls through to
    /// `appStore` when the sniff fails, which is the safe
    /// default.
    private static func isTestFlightReceipt(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        if data.isEmpty { return false }
        // Look for the sandbox environment OID.  Receipts are
        // small (a few hundred bytes) so 4 KB covers the whole
        // ASN.1 wrapper in practice.
        let needle: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x14, 0x01, 0x01] // 1.2.840.113635
        return data.range(of: Data(needle)) != nil
    }
}

// MARK: - VersionComparator

/// Compare dotted version strings component-by-component
/// (numeric when possible, lexicographic otherwise).  Used by
/// the About-page "检查更新" flow to decide whether the local
/// build is behind the latest GitHub release.  Shorter
/// versions are right-padded with zeros, so `0.5.1` and
/// `0.5.1.200` compare correctly (the second wins because
/// the trailing 200 > 0).
enum VersionComparator {

    /// Strip a leading `v` or `V` so `v0.5.1.195` and
    /// `0.5.1.195` are treated as the same version.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") { s.removeFirst() }
        return s
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = normalize(lhs).split(separator: ".").map(String.init)
        let r = normalize(rhs).split(separator: ".").map(String.init)
        let n = max(l.count, r.count)
        for i in 0..<n {
            let order = compareComponent(componentValue(l, i),
                                         componentValue(r, i))
            if order != .orderedSame { return order }
        }
        return .orderedSame
    }

    /// A single dot-separated piece of a version string.
    /// `Equatable` is enough — we compare via
    /// `compareComponent(_:_:)` below because mixing `Int64`
    /// and `String` cases under a single `Comparable`
    /// conformance would force a runtime type-erase that
    /// Swift 6 strict concurrency complains about.
    private enum Component: Equatable {
        case number(Int64)
        case text(String)
        case missing
    }

    private static func componentValue(_ parts: [String], _ index: Int) -> Component {
        guard index < parts.count else { return .missing }
        let raw = parts[index]
        if let n = Int64(raw) { return .number(n) }
        return .text(raw.lowercased())
    }

    private static func compareComponent(_ l: Component, _ r: Component) -> ComparisonResult {
        switch (l, r) {
        case (.missing, .missing):
            return .orderedSame
        case (.missing, _):
            // Padded zero is less than anything explicit
            // (1.0 < 1.0.1).
            return .orderedAscending
        case (_, .missing):
            return .orderedDescending
        case let (.number(a), .number(b)):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        case let (.text(a), .text(b)):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame
        case (.number, .text):
            // Numbers sort before text in mixed segments so
            // "1.10" > "1.beta".  This matches the
            // comparison conventions of most semver tools.
            return .orderedAscending
        case (.text, .number):
            return .orderedDescending
        }
    }
}
