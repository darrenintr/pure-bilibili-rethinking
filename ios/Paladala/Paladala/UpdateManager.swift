//
//  UpdateManager.swift
//  Paladala
//
//  Manages one-tap IPA download + SideStore installation flow.
//  When the user taps "下载并安装" on the About page after an
//  update check returns `.updateAvailable`, this manager:
//    1. Fetches the latest release assets from GitHub API
//    2. Downloads the unsigned IPA to Files.app temporary storage
//    3. Opens the IPA via UIDocumentInteractionController or
//       the SideStore URL scheme so the user can install
//
//  The download runs on a background URLSession so progress
//  is trackable and the user can leave the app mid-download.
//
//  Two install paths are exposed:
//    - `downloadAndInstallLatest()` — the legacy Shortcut-based
//      path. Downloads the IPA into the app's Documents folder
//      and invokes a user-installed Shortcut to hand it to
//      SideStore. Kept around because the Shortcut path is the
//      only way to install a freshly-downloaded IPA into
//      SideStore without a server-side AltSource.
//    - `installLatestFromStore(downloadURL:)` — the new path.
//      Hands the IPA URL directly to a sideload store via its
//      URL scheme (`altstore://install?url=…` or
//      `sidestore://install?url=…`), which avoids the
//      Shortcut + in-app download dance entirely. This is the
//      path the About page's "用 AltStore 安装" button now uses.
//
//

import Foundation
import UIKit

/// Manages the one-tap update flow: fetch release → download
/// IPA → invoke Shortcut to install via SideStore.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    @Published var updateDownloadState: UpdateDownloadState = .idle
    @Published var downloadProgress: Double = 0

    /// State of the URL-scheme-based install path. Distinct
    /// from `updateDownloadState` (which still drives the
    /// Shortcut path) so the two flows never share UI state
    /// by accident.
    @Published var installState: InstallState = .idle

    /// AltSource manifest URL. Re-used by the new install
    /// path as the Safari fallback when no sideload store is
    /// installed — the user opens it, refreshes the source,
    /// and installs from inside AltStore/SideStore.
    static let altSourceURL = URL(string:
        "https://darrenintr.github.io/pure-bilibili-rethinking/apps.json"
    )

    private var downloadTask: URLSessionDownloadTask?
    private var pendingIPAURL: URL? // Store the IPA download URL to pass to Shortcut

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.paladala.ipa-download"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Fetch the latest release from GitHub, find the unsigned
    /// IPA asset, and invoke the Shortcut to download and install.
    func downloadAndInstallLatest() async {
        // Check if Shortcut is installed
        guard ShortcutManager.shared.hasInstalledShortcut else {
            bpLog("UpdateManager: Shortcut not installed, prompting user")
            ShortcutManager.shared.checkAndPromptIfNeeded()
            await MainActor.run {
                updateDownloadState = .failed("請先安裝快捷指令")
            }
            return
        }

        guard updateDownloadState != .downloading else {
            bpLog("UpdateManager: download already in progress")
            return
        }

        await MainActor.run {
            updateDownloadState = .downloading
            downloadProgress = 0
        }

        do {
            // Step 1: fetch latest release JSON
            let release = try await fetchLatestRelease()
            guard let ipaAsset = release.assets?.first(where: { asset in
                asset.name?.contains("unsigned") == true &&
                asset.name?.hasSuffix(".ipa") == true
            }) else {
                throw UpdateError.noIPAFound
            }

            guard let downloadURL = ipaAsset.browser_download_url.flatMap(URL.init(string:)) else {
                throw UpdateError.invalidURL
            }

            bpLog("UpdateManager: found IPA at \(downloadURL.absoluteString)")

            // Step 2: invoke Shortcut to handle download and installation
            pendingIPAURL = downloadURL
            let success = ShortcutManager.shared.installIPA(from: downloadURL)

            await MainActor.run {
                if success {
                    updateDownloadState = .completed(downloadURL)
                    bpLog("UpdateManager: Shortcut invoked successfully")
                } else {
                    updateDownloadState = .failed("無法呼叫快捷指令")
                    bpLog("UpdateManager: failed to invoke Shortcut")
                }
            }

        } catch {
            bpLog("UpdateManager: download failed: \(error)")
            await MainActor.run {
                updateDownloadState = .failed(error.localizedDescription)
            }
        }
    }

    /// Cancel the active download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        updateDownloadState = .idle
        downloadProgress = 0
        pendingIPAURL = nil
    }

    // MARK: - URL-scheme install path
    //
    // The new About-page flow hands the IPA URL to a sideload
    // store (AltStore or SideStore) via its URL scheme. The
    // store fetches the IPA itself, signs it locally, and
    // prompts the user to install — so we never need to
    // download the bytes in-process or invoke a Shortcut.
    //
    // This is the path `updateAvailable(downloadURL:)` in
    // UpdateState drives.

    /// Hand `downloadURL` to a sideload store via its URL
    /// scheme. Tries AltStore first, falls back to
    /// SideStore; if neither store is installed, opens the
    /// AltSource manifest in Safari as a last-resort
    /// fallback (the user can refresh the source there and
    /// install from inside whichever store they end up
    /// adding).
    ///
    /// `installState` is updated as the call progresses so
    /// the About view can show a confirmation message. The
    /// actual install dialog appears in the store app, not
    /// in Paladala — the `opened(path:)` case just signals
    /// that the URL-scheme handoff succeeded.
    func installLatestFromStore(downloadURL: URL) async {
        installState = .opening
        bpLog("UpdateManager: installLatestFromStore \(downloadURL.absoluteString)")

        let encoded = downloadURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let altStoreURL = URL(string: "altstore://install?url=\(encoded)")
        let sideStoreURL = URL(string: "sidestore://install?url=\(encoded)")

        // `withCheckedContinuation`'s body is a non-isolated
        // closure in Swift 6, so we can't call MainActor-
        // isolated UIApplication methods from inside it
        // directly. Dispatch the work onto the main actor
        // with a `Task { @MainActor in … }` — the resume
        // happens from inside the open(_:options:
        // completionHandler:) completion handler, which
        // Apple documents as running on the main thread so
        // touching `cont` (a Sendable continuation) is safe.
        let path: InstallPath = await withCheckedContinuation { (cont: CheckedContinuation<InstallPath, Never>) in
            Task { @MainActor in
                // Try AltStore first. canOpenURL is the
                // standard way to detect whether the user
                // has installed a particular sideload
                // store; it returns false for undeclared
                // schemes, so the LSApplicationQueriesSchemes
                // entry in Info.plist is what makes this
                // work.
                if let altStoreURL, UIApplication.shared.canOpenURL(altStoreURL) {
                    UIApplication.shared.open(altStoreURL, options: [:]) { success in
                        bpLog("UpdateManager: altstore:// open success=\(success)")
                        cont.resume(returning: success ? .altStore : .none)
                    }
                } else if let sideStoreURL, UIApplication.shared.canOpenURL(sideStoreURL) {
                    UIApplication.shared.open(sideStoreURL, options: [:]) { success in
                        bpLog("UpdateManager: sidestore:// open success=\(success)")
                        cont.resume(returning: success ? .sideStore : .none)
                    }
                } else if let source = Self.altSourceURL {
                    // Neither store is installed. Fall back
                    // to the AltSource page in Safari;
                    // refreshing the source there is the
                    // same flow a first-time user would use
                    // anyway.
                    UIApplication.shared.open(source, options: [:]) { _ in
                        cont.resume(returning: .sourcePage)
                    }
                } else {
                    cont.resume(returning: .none)
                }
            }
        }

        switch path {
        case .altStore, .sideStore:
            installState = .opened(path: path)
        case .sourcePage:
            // Safari fallback is the best we can do without
            // a store installed; surface a distinct state so
            // the UI can hint at "在 AltStore 重新整理源後
            // 即可一鍵安裝".
            installState = .noStoreFound
        case .none:
            installState = .failed("無法開啟安裝頁")
        }
    }

    /// Reset the URL-scheme install state back to idle. The
    /// "用 AltStore 安裝" button calls this after the user
    /// returns to the app so the same tap can re-trigger
    /// another install attempt.
    func resetInstallState() {
        installState = .idle
    }

    // MARK: - Private

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let repoOwner = "darrenintr"
        let repoName = "pure-bilibili-rethinking"
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases?per_page=1") else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Paladala-iOS/\(AppVersion.current.marketingVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw UpdateError.networkError
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let latest = releases.first else {
            throw UpdateError.noReleaseFound
        }

        return latest
    }

    // Legacy download methods kept for fallback scenarios
    // (can be removed if Shortcut-only flow is preferred)

    private func startDownload(from url: URL, filename: String) async {
        let task = urlSession.downloadTask(with: url)
        downloadTask = task
        task.resume()
        bpLog("UpdateManager: started download task for \(filename)")
    }

    /// Present the downloaded IPA via UIDocumentInteractionController
    /// or try the SideStore URL scheme.
    private func presentIPA(at fileURL: URL) {
        // Strategy 1: try SideStore URL scheme first
        let encoded = fileURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let sideStoreURL = URL(string: "sidestore://install?url=\(encoded)"),
           UIApplication.shared.canOpenURL(sideStoreURL) {
            bpLog("UpdateManager: opening via SideStore URL scheme")
            UIApplication.shared.open(sideStoreURL)
            return
        }

        // Strategy 2: UIActivityViewController (share sheet)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            bpLog("UpdateManager: no root view controller to present share sheet")
            return
        }

        let activityVC = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        activityVC.excludedActivityTypes = [
            .addToReadingList,
            .assignToContact,
            .postToFacebook,
            .postToTwitter
        ]

        // iPad popover support
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(
                x: rootVC.view.bounds.midX,
                y: rootVC.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }

        bpLog("UpdateManager: presenting iOS share sheet")
        rootVC.present(activityVC, animated: true)
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move the temp file to a stable location in the app's
        // Documents directory so it survives the URLSession cleanup.
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = documentsURL.appendingPathComponent("Paladala-latest.ipa")

        do {
            // Remove any existing IPA at the destination
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)
            bpLog("UpdateManager: IPA saved to \(destinationURL.path)")

            Task { @MainActor in
                self.updateDownloadState = .completed(destinationURL)
                self.presentIPA(at: destinationURL)
            }
        } catch {
            bpLog("UpdateManager: failed to move IPA: \(error)")
            Task { @MainActor in
                self.updateDownloadState = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.downloadProgress = progress
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            bpLog("UpdateManager: download task failed: \(error)")
            Task { @MainActor in
                self.updateDownloadState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - UpdateDownloadState

enum UpdateDownloadState: Equatable {
    case idle
    case downloading
    case completed(URL)
    case failed(String)
}

// MARK: - InstallState (URL-scheme flow)
//
// Distinct from `UpdateDownloadState` (which drives the
// Shortcut path) so the two flows never share UI state.
// `opened(path:)` is reached once the URL-scheme handoff to
// the store app has succeeded; the actual install dialog
// appears in the store, not in Paladala.

enum InstallState: Equatable {
    case idle
    case opening
    case opened(path: InstallPath)
    case noStoreFound
    case failed(String)
}

/// Which store app received the URL-scheme handoff. Drives
/// the confirmation label under the install button
/// (AltStore vs SideStore) and the Safari fallback hint.
enum InstallPath: String, Equatable, Sendable {
    case altStore
    case sideStore
    /// User has neither store installed; we opened the
    /// AltSource page in Safari as a last-resort hint.
    case sourcePage
    /// Handoff attempted but `open(_:options:completionHandler:)`
    /// returned false. Treated like `.none` for state purposes.
    case none
}

// MARK: - UpdateError

enum UpdateError: LocalizedError {
    case invalidURL
    case networkError
    case noReleaseFound
    case noIPAFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "無效的下載地址"
        case .networkError:
            return "網路請求失敗"
        case .noReleaseFound:
            return "未找到可用的釋出版本"
        case .noIPAFound:
            return "該版本沒有 unsigned IPA 檔案"
        }
    }
}

// MARK: - GitHub API models

struct GitHubRelease: Decodable {
    let tag_name: String?
    let name: String?
    let html_url: String?
    let assets: [GitHubAsset]?
}

struct GitHubAsset: Decodable {
    let name: String?
    let browser_download_url: String?
    let size: Int?
}
