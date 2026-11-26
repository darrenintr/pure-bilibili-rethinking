import Foundation

/// Persistent, on-disk record of every video the user has
/// downloaded.  The store is the single source of truth for
/// the "下载" tab; it does *not* own the bytes themselves —
/// those live under
/// `Caches/Paladala/Downloads/ready/{bvid}/`, and the store
/// points to them.
///
/// Concurrency model
/// -----------------
///
/// `DownloadStore` is a `@MainActor` `ObservableObject` —
/// SwiftUI views can observe `records` directly.  All disk
/// I/O hops onto a dedicated background `DispatchQueue` so
/// the main thread is never blocked by the manifest rewrite
/// (the manifest is small — order of 200 bytes per record —
/// but `Data.write(to:options: .atomic)` does an
/// `fsync`-equivalent and is unpredictable on a hot path).
///
/// The on-disk manifest is rewritten via `Data.write(to:
/// options: .atomic)` so a crash mid-write cannot leave the
/// user with a partial JSON file.  iOS replaces the file
/// atomically via a temporary + rename, and the old content
/// is recoverable from the OS-level recycle bin if the
/// rename never happens.
///
/// Storage location
/// ----------------
///
/// `Caches/` rather than `Documents/` — iOS may purge
/// `Caches/` under storage pressure, but the user's downloads
/// are re-derivable from the B 站 CDN so the trade-off is
/// correct.  `Documents/` would block iCloud backup of the
/// app, which we do not want for 70 MB video files.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    /// All currently-downloaded records, ordered by
    /// `downloadedAt` descending (newest first).  SwiftUI
    /// views observe this and re-render when it changes.
    @Published private(set) var records: [DownloadRecord] = []

    /// Root of every download-related file the store owns.
    /// `Caches/Paladala/Downloads/` — `manifest.json` lives at
    /// the root, with two child directories:
    ///   - `in_progress/{bvid}/` — staging, never read by the
    ///     player
    ///   - `ready/{bvid}/`       — atomic-swap destination
    /// Marked `nonisolated` so `DownloadManager`'s URLSession
    /// delegate (which runs on a non-MainActor queue) can
    /// compute the staging path without an actor hop.  The
    /// static values are derived from `Caches` and never
    /// change after process start, so concurrency is trivial.
    nonisolated static let rootURL: URL = {
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first!
        return caches
            .appendingPathComponent("Paladala", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }()

    nonisolated static let inProgressURL: URL = rootURL
        .appendingPathComponent("in_progress", isDirectory: true)
    nonisolated static let readyURL: URL = rootURL
        .appendingPathComponent("ready", isDirectory: true)
    nonisolated static let manifestURL: URL = rootURL
        .appendingPathComponent("manifest.json")

    /// Background queue.  Serial, so two concurrent writes do
    /// not race.  All disk I/O for the manifest + on-disk
    /// layout hops here.
    private let ioQueue = DispatchQueue(
        label: "Paladala.DownloadStore.io",
        qos: .userInitiated
    )
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        // Hydrate the in-memory record list before the
        // singleton first becomes visible to callers.
        // `DownloadStore` is `@MainActor`-isolated, so `init()`
        // runs on the main actor the first time `.shared` is
        // touched — synchronously, with no async hop.
        //
        // The manifest is tiny (~200 bytes per record); even
        // hundreds of records decode in <5 ms on cold cache,
        // which is acceptable as launch work.
        //
        // Without this, a user tapping a downloaded video
        // from the Home feed races the old async hydration
        // in `loadFromDisk()` (the `PaladalaAppDelegate` fired
        // it inside a fire-and-forget `Task { @MainActor in
        // … }`).  `record(for:)` returned nil, the
        // offline-first branch in
        // `VideoDetailViewModel.load` was skipped, and the
        // VM tried the online `repository.playback(for:)`,
        // which fails offline even though the bytes are
        // sitting in `Caches/Paladala/Downloads/ready/{bvid}/`.
        self.records = hydrateFromDiskSync()
        migrateLegacyLayouts()
    }

    /// One-shot migration for downloads made before the merge
    /// step worked: any record that still has the legacy
    /// 4-file layout (`{video,audio}.{init,media}`) but no
    /// merged `video.mp4` gets merged in place. Runs on
    /// `ioQueue` — the byte-copy of a few hundred MB must not
    /// sit on the main actor during launch. Idempotent: the
    /// merge itself skips tracks whose output already exists.
    private func migrateLegacyLayouts() {
        let snapshot = records
        ioQueue.async {
            for record in snapshot {
                let directory = self.readyDirectory(for: record.bvid)
                let fm = FileManager.default
                let mergedVideo = directory.appendingPathComponent("video.mp4")
                guard !fm.fileExists(atPath: mergedVideo.path) else { continue }
                let legacyVideoInit = directory.appendingPathComponent("video.init")
                guard fm.fileExists(atPath: legacyVideoInit.path) else { continue }
                let result = DownloadManager.mergeSegmentsIntoMp4(
                    staging: directory,
                    hasAudio: record.dash.audio != nil
                )
                diagLog(.download, "legacy layout migration",
                        details: [
                            "bvid": record.bvid,
                            "merged": result.ok,
                            "video_bytes": result.videoBytes,
                            "audio_bytes": result.audioBytes
                        ])
            }
        }
    }

    // MARK: lifecycle

    /// Read the manifest from disk and rebuild the in-memory
    /// record list.  Synchronous: the manifest is small
    /// (~200 bytes per record) and decoding is fast, so we
    /// do it on the caller's thread rather than hopping
    /// through `ioQueue`.  `init()` already calls this at
    /// launch so callers can rely on `records` being
    /// populated before `.shared` first appears — this
    /// method is kept public for explicit refreshes (e.g.
    /// after an external write to the manifest, which we do
    /// not currently do).
    func loadFromDisk() {
        records = hydrateFromDiskSync()
    }

    /// Pure read-and-decode helper used by `init()` and
    /// `loadFromDisk()`.  Creates the on-disk directory
    /// layout as a side effect so callers do not have to
    /// remember to do so separately.
    ///
    /// Path-storage note: the on-disk directory
    /// (`Caches/Paladala/Downloads/ready/{bvid}/`) is *never*
    /// persisted in `manifest.json` — the manifest holds only
    /// `bvid` + metadata, and the directory URL is
    /// recomputed from `bvid` on every read via
    /// `readyDirectory(for:)`.  iOS may rotate the sandbox
    /// container UUID between launches (Build 126's
    /// 443D6288-… became Build 127's 579E46FD-…, for
    /// example), so persisting any absolute path would
    /// silently rot on the next build.
    private func hydrateFromDiskSync() -> [DownloadRecord] {
        do {
            try FileManager.default.createDirectory(
                at: Self.rootURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: Self.inProgressURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: Self.readyURL,
                withIntermediateDirectories: true
            )
        } catch {
            bpLog("DownloadStore could not create dirs: \(error)")
        }
        let onDisk: [DownloadRecord]
        do {
            let data = try Data(contentsOf: Self.manifestURL)
            onDisk = (try? self.decoder.decode(
                [DownloadRecord].self, from: data
            )) ?? []
        } catch {
            // File missing is the common case on first
            // launch — not an error.  Any other read
            // failure falls back to "empty" so the user
            // can still use the app; a fresh manifest is
            // written on the next mutation.
            onDisk = []
        }
        // We deliberately do NOT prune manifest entries whose
        // on-disk bytes have been lost (Caches purge, sandbox
        // rotate, etc.).  Silently dropping the record was the
        // root cause of the "downloaded video can't open"
        // user-visible regression: the user saw a download
        // succeed, the next launch showed the record gone, and
        // they could not tell whether to re-download or trust
        // the existing files.  Instead, we keep the manifest
        // entry and surface a `hasCompleteLocalBytes: false`
        // state to the UI via `verifyLocalBytes(for:)`, so the
        // player can fall back to the online path and the
        // Downloads screen can offer "重新下载".  A single
        // audit line per launch makes the discrepancy visible
        // in the diagnostic report.
        let missing = onDisk.filter { record in
            !hasCompleteLocalBytes(for: record)
        }
        if !missing.isEmpty {
            let missingBvids = missing.map { $0.bvid }
            bpLog("DownloadStore hydrate: \(missing.count) record(s) have no on-disk bytes (Caches purge?). bvids=\(missingBvids)")
            diagLog(.download, "DownloadStore hydrate missing bytes",
                    details: [
                        "missingCount": missing.count,
                        "bvids": missingBvids.joined(separator: ",")
                    ])
        }
        return onDisk
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    /// Returns `true` only when every track implied by the
    /// manifest still has its on-disk bytes.  Two layouts are
    /// recognised:
    ///
    ///   1. **Merged** (`video.mp4` + optional `audio.mp4`) —
    ///      the canonical layout the download manager writes
    ///      from commit `85971957e+merge` onward.  A single
    ///      self-contained mp4 per track is easier to
    ///      integrity-check and eliminates the upstream-
    ///      offset byte-range math the old layout required.
    ///   2. **Legacy 4-file** (`{video,audio}.{init,media}`) —
    ///      kept so existing downloads made before the merge
    ///      step still play.  When both layouts exist, the
    ///      merged files win.
    ///
    /// iOS may purge `Caches/` under storage pressure; when
    /// that happens we do not want to keep surfacing a
    /// manifest entry that can never play.
    /// Pure read against the on-disk layout — does not touch
    /// the singleton's mutable state.  Marked `nonisolated`
    /// so the `DownloadStore.ioQueue` worker (a non-MainActor
    /// `DispatchQueue`) can call it during the post-move
    /// integrity check without an actor hop.
    nonisolated func hasCompleteLocalBytes(for record: DownloadRecord) -> Bool {
        let directory = readyDirectory(for: record.bvid)
        let fm = FileManager.default
        let videoMerged = directory.appendingPathComponent("video.mp4")
        let audioMerged = directory.appendingPathComponent("audio.mp4")
        let hasMerged = fm.fileExists(atPath: videoMerged.path)
            && (record.dash.audio == nil
                || fm.fileExists(atPath: audioMerged.path))
        if hasMerged {
            return true
        }
        // Legacy fallback: keep older downloads playable.
        func hasBothFiles(_ trackName: String) -> Bool {
            let initURL = directory.appendingPathComponent("\(trackName).init")
            let mediaURL = directory.appendingPathComponent("\(trackName).media")
            return fm.fileExists(atPath: initURL.path) &&
                   fm.fileExists(atPath: mediaURL.path)
        }
        guard hasBothFiles("video") else { return false }
        if record.dash.audio != nil, !hasBothFiles("audio") {
            return false
        }
        return true
    }

    /// Returns the URLs of the merged mp4 files for `bvid`, or
    /// `nil` for the video slot when the merge has not run.
    /// Used by `VideoDetailViewModel` to populate
    /// `LocalPlaybackContext.mergedVideo` / `.mergedAudio` so
    /// `AVPlayerController` can take the fast direct-file path
    /// and skip the local HLS proxy entirely.
    ///
    /// Returned video URL is `nil` (rather than a non-existent
    /// URL) when the merge failed or has not yet completed —
    /// callers check `nil` first to choose between the proxy
    /// path and the direct-file path.
    func mergedFileURLs(for bvid: String) -> (video: URL?, audio: URL?) {
        let directory = readyDirectory(for: bvid)
        let fm = FileManager.default
        let videoURL = directory.appendingPathComponent("video.mp4")
        let audioURL = directory.appendingPathComponent("audio.mp4")
        let video = fm.fileExists(atPath: videoURL.path) ? videoURL : nil
        let audio = fm.fileExists(atPath: audioURL.path) ? audioURL : nil
        return (video, audio)
    }

    /// Sum of the byte sizes of every file under `directory`.
    /// Returns 0 when the directory does not exist.  Used by
    /// the post-move integrity check in `add(_:)` to make a
    /// no-bytes-moved failure mode visible — without this
    /// `moveItem` can succeed (returning no error) while the
    /// destination is empty, and the manifest then records a
    /// download that has no bytes.
    /// `nonisolated` because the only state touched is the
    /// `FileManager` singleton (thread-safe) and the input
    /// URL; the caller (ioQueue worker) is on a background
    /// queue, not MainActor.
    nonisolated private func directorySize(_ directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(
                forKeys: [.fileSizeKey]
            ))?.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: directory helpers

    /// On-disk directory for a `bvid` in the ready (final)
    /// state.  Computed from `readyURL` so the URL stays
    /// valid even if iOS rotates the Caches container.
    /// On-disk directory for a `bvid` in the ready (final)
    /// state.  Computed from `readyURL` so the URL stays
    /// valid even if iOS rotates the Caches container.
    /// `nonisolated` because the ioQueue worker calls it
    /// from a background `DispatchQueue`.
    nonisolated func readyDirectory(for bvid: String) -> URL {
        Self.readyURL.appendingPathComponent(bvid, isDirectory: true)
    }

    /// On-disk directory for a `bvid` in the in-progress
    /// (staging) state.  Symmetric to `readyDirectory(for:)`.
    nonisolated func inProgressDirectory(for bvid: String) -> URL {
        Self.inProgressURL.appendingPathComponent(bvid, isDirectory: true)
    }

    // MARK: mutation

    /// Promote a finished download into the ready state.  The
    /// `in_progress/{bvid}/` directory is moved to
    /// `ready/{bvid}/` (atomic on APFS), the manifest is
    /// rewritten, and the in-memory `records` is updated.
    ///
    /// Post-move verification: after `moveItem` returns, the
    /// caller is told "the bytes are on disk in `ready/{bvid}/`".
    /// In practice we have seen the move succeed at the
    /// Foundation level (no `NSError`) while the destination
    /// directory is empty — see diagnostic
    /// `Paladala_Diagnostic_1782994463.txt` where
    /// `ready/ total bytes: 0` immediately after a `move success`
    /// event.  The root cause is OS-level `Caches/` purging that
    /// races the move, plus a path mismatch where the staging
    /// directory was empty before the move ran.  To avoid
    /// poisoning the manifest with a phantom record, we stat
    /// the destination right after the move and refuse to
    /// persist the record when the bytes are not there.
    func add(_ record: DownloadRecord) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let staging = self.inProgressDirectory(for: record.bvid)
            let destination = self.readyDirectory(for: record.bvid)
            do {
                // The destination might exist from a prior
                // download of the same `bvid` (the user
                // re-downloaded).  Remove it first so
                // `moveItem` does not fail with
                // `NSFileWriteFileExistsError`.
                if FileManager.default.fileExists(
                    atPath: destination.path
                ) {
                    try FileManager.default.removeItem(
                        at: destination
                    )
                }
                try FileManager.default.moveItem(
                    at: staging, to: destination
                )
                diagLog(.download, "DownloadStore move success",
                        details: [
                            "bvid": record.bvid,
                            "from": staging.lastPathComponent,
                            "to": destination.lastPathComponent
                        ])
            } catch {
                bpLog("DownloadStore move failed: \(error)")
                diagLog(.download, "DownloadStore move failed",
                        details: [
                            "bvid": record.bvid,
                            "from": staging.lastPathComponent,
                            "to": destination.lastPathComponent,
                            "error": "\(error)"
                        ])
                // Recover: drop the staging dir to avoid
                // growing the in_progress folder unbounded.
                try? FileManager.default.removeItem(at: staging)
                return
            }
            // Post-move integrity check.  If the destination
            // directory is missing the expected init / media
            // files we MUST NOT persist the manifest entry —
            // otherwise the next launch surfaces a "downloaded"
            // record whose bytes the player cannot find.  Log
            // a single high-signal diagnostic and fall back to
            // cleaning the empty destination.
            if !self.hasCompleteLocalBytes(for: record) {
                let size = self.directorySize(destination)
                bpLog("DownloadStore post-move verify failed: \(record.bvid) dir=\(destination.path) size=\(size)")
                diagLog(.download, "DownloadStore post-move verify failed",
                        details: [
                            "bvid": record.bvid,
                            "destination": destination.path,
                            "destinationSize": size
                        ])
                try? FileManager.default.removeItem(at: destination)
                return
            }
            self.appendRecord(record)
        }
    }

    /// Remove a record (and the on-disk directory).  No-op if
    /// the record does not exist.  Used by the
    /// swipe-to-delete action in `DownloadedVideosView`.
    func remove(bvid: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let directory = self.readyDirectory(for: bvid)
            try? FileManager.default.removeItem(at: directory)
            Task { @MainActor in
                self.records.removeAll { $0.bvid == bvid }
                self.persistAsync()
            }
        }
    }

    /// Look up a record by `bvid`.  Used by
    /// `PlayerController` to wire `BiliPlayback.localContext`
    /// when the user opens a downloaded video.
    func record(for bvid: String) -> DownloadRecord? {
        records.first { $0.bvid == bvid }
    }

    /// Confirm that the on-disk bytes for `record` are still
    /// present.  Returns `true` when both the video and (if
    /// present) the audio track's init / media files exist on
    /// disk.  Used by the player before opening a downloaded
    /// video so it can fall back to the online path when the
    /// manifest says "downloaded" but the bytes have been
    /// purged (most commonly by iOS reclaiming `Caches/`
    /// under storage pressure).  Without this check the
    /// player would call `LocalHLSProxyServer.serveLocal(...)`
    /// and get a 404 from the local proxy, which the user
    /// perceives as a "video cannot open" regression.
    func verifyLocalBytes(for record: DownloadRecord) -> Bool {
        hasCompleteLocalBytes(for: record)
    }

    // MARK: internal mutation

    /// Insert + persist a new record.  Caller has already
    /// moved the staging directory into place.
    ///
    /// Marked `nonisolated` so it is callable from the
    /// background `ioQueue` (in `add(_:)`); the actual
    /// mutation hops to the main actor via `Task { @MainActor in … }`.
    /// `records` is `@MainActor`-isolated because SwiftUI
    /// views observe it directly.
    nonisolated fileprivate func appendRecord(_ record: DownloadRecord) {
        Task { @MainActor in
            self.records.removeAll { $0.bvid == record.bvid }
            self.records.append(record)
            self.records.sort { $0.downloadedAt > $1.downloadedAt }
            self.persistAsync()
        }
    }

    /// Write the in-memory `records` to `manifest.json`.  Safe
    /// to call repeatedly — `Data.write(to:options:
    /// .atomic)` is idempotent.
    fileprivate func persistAsync() {
        let snapshot = records
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try self.encoder.encode(snapshot)
                try data.write(to: Self.manifestURL, options: .atomic)
            } catch {
                bpLog("DownloadStore persist failed: \(error)")
            }
        }
    }
}
