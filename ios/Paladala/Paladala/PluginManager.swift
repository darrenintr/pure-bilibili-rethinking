//
//  PluginManager.swift
//  Paladala
//
//  Loads built-in and user-installed JSON plugin rules and
//  exposes them to the four hook sites (sponsorblock, cdn,
//  danmaku, brightness).  The "BASIC but WORKING" surface:
//  bundles ship disabled, paste-from-textbox is the only
//  import path (no URL fetcher yet), per-plugin toggle writes
//  back to disk so the choice survives a relaunch.
//

import Foundation
import Combine

/// `@MainActor` to match the rest of the project's
/// `ObservableObject` types (e.g. `SponsorBlockManager`) and
/// to satisfy Swift 6 strict concurrency — `@Published`
/// mutations are expected to happen on the main actor.
///
/// The one non-main-actor call site
/// (`AVPlayerController.init`'s `cdnPin` lookup) wraps the
/// call in `MainActor.assumeIsolated`, which is fine because
/// that init always runs on the main thread in practice
/// (`MiniPlayerStore` calls it from view lifecycle).
@MainActor
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    /// Combined view of bundled + on-disk plugins. `origin`
    /// tells the settings UI which rows can be deleted.
    @Published private(set) var plugins: [Plugin] = []

    /// Failures while decoding a JSON file. Surfaced in the
    /// settings view so a bad paste doesn't silently no-op.
    @Published private(set) var loadErrors: [String] = []

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.allowsJSON5 = false
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Path to `~/Library/Application Support/Paladala/Plugins`.
    private lazy var pluginsDir: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Paladala/Plugins", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Pre-compiled regex cache, keyed by pattern string. Built
    /// lazily on first call.  Compiled NSRegularExpression is
    /// thread-safe to share as long as we don't mutate it.
    private var regexCache: [String: NSRegularExpression?] = [:]

    private init() {
        reload()
    }

    // MARK: - Public API

    /// Force a reload from disk + bundle. Cheap to call on
    /// view `onAppear` so the settings UI reflects external
    /// edits. Bundled entries are never re-loaded from disk
    /// because they ship in the .app bundle — their state is
    /// in `UserDefaults` overrides (keyed by `id`) applied on
    /// top.
    func reload() {
        var collected: [Plugin] = []
        collected.append(contentsOf: loadBundled())
        collected.append(contentsOf: loadDisk())
        plugins = collected
    }

    /// Add a plugin from raw JSON text (paste-in path). Decodes
    /// via the same decoder used for disk files and persists to
    /// a new file in the plugins directory.
    func add(plainText: String) throws {
        guard let data = plainText.data(using: .utf8) else {
            throw PluginError.invalidEncoding
        }
        let plugin = try decoder.decode(Plugin.self, from: data)
        try persist(plugin)
        reload()
    }

    /// Flip the on/off flag. Bundled plugins are tracked in
    /// `UserDefaults` (key `paladala.plugins.bundled.<id>`)
    /// because their JSON lives in the app bundle and can't
    /// be rewritten. Disk plugins are rewritten in place.
    func toggle(id: String, on: Bool) throws {
        if let idx = plugins.firstIndex(where: { $0.id == id }),
           let origin = plugins[idx].origin {
            var updated = plugins[idx]
            updated.enabled = on
            plugins[idx] = updated
            switch origin {
            case .bundled:
                UserDefaults.standard.set(on, forKey: bundledOverrideKey(id))
            case .disk(let filename):
                try persist(updated, to: pluginsDir.appendingPathComponent(filename))
            }
        }
    }

    /// Delete a disk-installed plugin. No-op for bundled ones.
    func delete(id: String) {
        guard let plugin = plugins.first(where: { $0.id == id }),
              case .disk(let filename) = plugin.origin else { return }
        let url = pluginsDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    // MARK: - Hook helpers

    /// SponsorBlock extras applicable to this video, across all
    /// enabled plugins.  Each extra is converted to the
    /// existing `SponsorSegment` shape so it goes through
    /// `SponsorBlockManager.loadSegments`'s normal path.
    func sponsorExtras(for videoID: String) -> [SponsorSegment] {
        var extras: [SponsorSegment] = []
        for plugin in plugins where plugin.enabled {
            guard let segs = plugin.rules?.sponsorblock?.extraSegments else { continue }
            for s in segs where s.videoID == videoID {
                // Synthesize a stable UUID per (plugin, segment) so repeated
                // loads land on a stable id and the diagnostic log reads cleanly.
                let uuid = "plugin-\(plugin.id)-\(s.videoID)-\(s.startTime)-\(s.endTime)"
                extras.append(
                    SponsorSegment(
                        uuid: uuid,
                        videoID: s.videoID,
                        cid: nil,
                        segment: [s.startTime, s.endTime],
                        category: s.category,
                        actionType: "skip",
                        locked: 0,
                        votes: 1_000_000,
                        views: 0,
                        userID: nil,
                        description: nil
                    )
                )
            }
        }
        return extras
    }

    /// CDN host pin: first enabled plugin that declared a
    /// non-empty host wins. Returns nil if none. Per-video
    /// scope is intentionally global — if you want
    /// per-video routing, edit the JSON `pinHost`.
    func cdnPin(for videoID: String) -> String? {
        for plugin in plugins where plugin.enabled {
            if let host = plugin.rules?.cdn?.pinHost, !host.isEmpty {
                return host
            }
        }
        return nil
    }

    /// Apply enabled-plugin filters to a danmaku batch: drop
    /// entries matching `filterRegex` first, then cap the
    /// remaining set to `maxDensity` items (kept in playback
    /// order so the earliest messages survive).
    func danmakuFilter(items: [BiliDanmakuItem]) -> [BiliDanmakuItem] {
        var working = items
        var compiledRegex: NSRegularExpression? = nil
        var compiledSource: String? = nil
        for plugin in plugins where plugin.enabled {
            if let pattern = plugin.rules?.danmaku?.filterRegex,
               !pattern.isEmpty {
                if compiledSource != pattern {
                    compiledSource = pattern
                    compiledRegex = try? NSRegularExpression(pattern: pattern)
                }
                if let regex = compiledRegex {
                    working = working.filter { item in
                        let range = NSRange(item.text.startIndex..., in: item.text)
                        return regex.firstMatch(in: item.text, range: range) == nil
                    }
                }
            }
            if let cap = plugin.rules?.danmaku?.maxDensity, cap > 0,
               working.count > cap {
                working = Array(working.prefix(cap))
            }
        }
        return working
    }

    /// First enabled brightness rule — `PluginManager` only
    /// ever surfaces one so we don't stack overlays. Returns
    /// nil when no plugin is enabled.
    func brightnessRule() -> PluginBrightnessRule? {
        for plugin in plugins where plugin.enabled {
            if let b = plugin.rules?.brightness,
               (b.level != nil || b.warmth != nil) {
                return b
            }
        }
        return nil
    }

    // MARK: - Internals

    private func bundledOverrideKey(_ id: String) -> String {
        "paladala.plugins.bundled.\(id)"
    }

    private func loadBundled() -> [Plugin] {
        let bundle = Bundle.main
        guard let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Plugins")
                ?? Self.scanBundleRecursively(bundle: bundle, subdirectory: "Plugins") else {
            return []
        }
        var out: [Plugin] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                var plugin = try decoder.decode(Plugin.self, from: data)
                plugin.origin = .bundled
                // Apply per-bundled override; default is the
                // JSON-shipped `enabled` flag.
                let key = bundledOverrideKey(plugin.id)
                if UserDefaults.standard.object(forKey: key) != nil {
                    plugin.enabled = UserDefaults.standard.bool(forKey: key)
                }
                out.append(plugin)
            } catch {
                loadErrors.append("Bundled: \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return out
    }

    /// Some Xcode versions don't honour `subdirectory:` for
    /// bundled resources; fall back to a shallow scan if so.
    private static func scanBundleRecursively(bundle: Bundle, subdirectory: String) -> [URL]? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let dir = resourceURL.appendingPathComponent(subdirectory, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }
    }

    private func loadDisk() -> [Plugin] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [Plugin] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: url)
                var plugin = try decoder.decode(Plugin.self, from: data)
                plugin.origin = .disk(filename: url.lastPathComponent)
                out.append(plugin)
            } catch {
                loadErrors.append("Disk: \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return out
    }

    private func persist(_ plugin: Plugin) throws {
        let safeID = plugin.id.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression
        )
        let filename = safeID.isEmpty ? UUID().uuidString : safeID
        let url = pluginsDir.appendingPathComponent("\(filename).json")
        try persist(plugin, to: url)
    }

    private func persist(_ plugin: Plugin, to url: URL) throws {
        var copy = plugin
        // Strip the runtime-only origin before serialising.
        copy.origin = nil
        let data = try encoder.encode(copy)
        try data.write(to: url, options: [.atomic])
    }
}

enum PluginError: LocalizedError {
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "無法解析為文字。"
        }
    }
}
