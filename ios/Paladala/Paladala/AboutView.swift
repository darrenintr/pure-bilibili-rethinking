//
//  AboutView.swift
//  Paladala
//
//  "关于" (About) screen reachable from the 我的 (Profile)
//  settings list.  Surfaces the build identity (marketing
//  version, build number, special identifier, release type,
//  channel, commit, build date, bundle ID) and provides a
//  "检查更新" action that hits the GitHub Releases API for
//  the project's public repository.
//
//  Identity values come from `AppVersion.current` — see
//  AppVersion.swift for the fingerprint algorithm and the
//  fallback path used by local dev builds.
//

import SwiftUI
import UIKit

struct AboutView: View {
    /// Static fallback link to the project's GitHub Releases
    /// tab. Shown as a secondary action on the update card
    /// so a user without a sideload store can still grab the
    /// IPA + changelog manually.
    private static let gitHubReleasesURL = URL(string:
        "https://github.com/darrenintr/pure-bilibili-rethinking/releases"
    )

    @State private var version = AppVersion.current
    @State private var copyToast: String? = nil
    @State private var updateState: UpdateState = .idle
    @StateObject private var updateManager = UpdateManager.shared
    @StateObject private var shortcutManager = ShortcutManager.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            headerSection
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)

            Section {
                identityRow(label: L10n.about.version, value: version.marketingVersion)
                identityRow(label: L10n.about.build, value: version.buildNumber)
                identifierRowStyled
                identityRow(label: L10n.about.releaseType, value: version.releaseTypeDisplay)
                identityRow(label: L10n.about.channel, value: version.channel.nonEmptyOrDash)
                if let commit = version.commitShort {
                    identityRow(label: L10n.about.commit, value: commit)
                }
                identityRow(label: L10n.about.buildDate, value: formatDate(version.buildDate))
                identityRow(label: L10n.about.bundleId, value: version.bundleId)
            } header: {
                Text("構建資訊")
            } footer: {
                Text("特別辨識號用於精確標識當前構建，反饋問題時附上它可以幫我們快速定位。")
            }

            Section {
                Button {
                    checkForUpdates()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(L10n.about.checkForUpdates)
                            .foregroundStyle(.primary)
                        Spacer()
                        if case .checking = updateState {
                            ProgressView()
                        }
                    }
                }
                .disabled(updateState == .checking)

                if updateState != .idle {
                    updateResultCard
                }
            } header: {
                Text("更新")
            } footer: {
                Text(L10n.about.checkSourceHint)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(PaladalaTheme.canvas)
        .navigationTitle(L10n.about.title)
        .overlay(alignment: .bottom) {
            if let toast = copyToast {
                Text(toast)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $shortcutManager.showInstallPrompt) {
            ShortcutInstallPromptView()
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 10) {
            // App-icon-style glyph: the same glass TV mark as the
            // splash screen, rendered natively — no "BP" mono
            // placeholder.
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18).gradient)
                Image(systemName: "tv.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 88, height: 88)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

            Text("Paladala")
                .font(.title.weight(.bold))

            Text("Pure Bilibili · Native iOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(version.versionLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func identityRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var identifierRowStyled: some View {
        Button {
            copyIdentifier()
        } label: {
            HStack(spacing: 12) {
                Text(L10n.about.identifier)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(version.identifierDisplay)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                Image(systemName: "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var updateResultCard: some View {
        switch updateState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text(L10n.about.checking)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let remote):
            Label("\(L10n.about.upToDate) · \(remote)", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        case .updateAvailable(let remote, let downloadURL):
            updateAvailableRows(remote: remote, downloadURL: downloadURL)
        case .devBuild(let remote, let downloadURL):
            devBuildRows(remote: remote, downloadURL: downloadURL)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        }
    }

    @ViewBuilder
    private func updateAvailableRows(remote: String, downloadURL: URL?) -> some View {
        Label("\(L10n.about.updateAvailable) · \(remote)", systemImage: "arrow.up.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .symbolRenderingMode(.multicolor)
        installRows(downloadURL: downloadURL)
    }

    @ViewBuilder
    private func devBuildRows(remote: String?, downloadURL: URL?) -> some View {
        Label(L10n.about.devBuild, systemImage: "hammer.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
        if let remote {
            Text("\(L10n.about.upToDate) · \(remote)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        installRows(downloadURL: downloadURL)
    }

    @ViewBuilder
    private func installRows(downloadURL: URL?) -> some View {
        if let downloadURL {
            Button {
                Task {
                    await updateManager.installLatestFromStore(downloadURL: downloadURL)
                }
            } label: {
                HStack {
                    if updateManager.installState == .opening {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(installButtonLabel)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(updateManager.installState == .opening)
        } else {
            Button {
                Task {
                    await updateManager.downloadAndInstallLatest()
                }
            } label: {
                Label(L10n.about.openInAltStore, systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(updateManager.updateDownloadState == .downloading)
        }

        installStatusMessages

        if let url = Self.gitHubReleasesURL {
            Button {
                openURL(url)
            } label: {
                Label(L10n.about.viewOnGitHub, systemImage: "arrow.up.right.square")
                    .font(.callout)
            }
            .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private var installStatusMessages: some View {
        switch updateManager.installState {
        case .idle, .opening, .opened:
            EmptyView()
        case .noStoreFound:
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.about.noStoreDetected, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("已為你開啟源頁,喺 AltStore / SideStore 重新整理源後即可一鍵安裝。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if case .failed(let error) = updateManager.updateDownloadState {
            if error.contains("快捷指令") {
                Button {
                    shortcutManager.checkAndPromptIfNeeded()
                } label: {
                    Label("設定快捷指令", systemImage: "wrench.and.screwdriver")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var installButtonLabel: String {
        switch updateManager.installState {
        case .opening:
            return L10n.about.opening
        case .opened(let path):
            switch path {
            case .altStore:
                return L10n.about.openInAltStore
            case .sideStore:
                return L10n.about.openInSideStore
            case .sourcePage, .none:
                return L10n.about.openInAltStore
            }
        case .noStoreFound, .failed:
            return L10n.about.openInAltStore
        case .idle:
            return L10n.about.openInAltStore
        }
    }

    private func copyIdentifier() {
        UIPasteboard.general.string = version.identifierDisplay
        Haptics.selection()
        withAnimation(.easeOut(duration: 0.18)) {
            copyToast = L10n.about.identifierCopied
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(.easeIn(duration: 0.22)) {
                copyToast = nil
            }
        }
    }

    private func checkForUpdates() {
        // The new AltSource-based check does not require a
        // Shortcut to be installed — the install path is
        // a URL-scheme handoff to AltStore / SideStore, so
        // the gate that used to live here (prompting the
        // user to install a Shortcut before we even asked
        // the server) is gone.
        updateState = .checking
        Task {
            let result = await UpdateChecker.check(current: version)
            await MainActor.run {
                updateState = result
            }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return f.string(from: date)
    }
}

// MARK: - UpdateState

/// Result of the most recent "检查更新" tap.  Drives the
/// inline message under the button.  All cases except
/// `.idle` and `.checking` carry enough context for the
/// row to render a complete message without a follow-up
/// network call.
enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(remote: String)
    /// Remote `apps.json` reports a newer version than the
    /// local build. `downloadURL` is the unsigned IPA URL
    /// from `versions[0]` — passed to AltStore / SideStore
    /// via the URL-scheme install path. `remote` is the
    /// marketing-version line shown to the user (e.g.
    /// "0.5.2 (3)").
    case updateAvailable(remote: String, downloadURL: URL?)
    /// Local build is a development / sideloaded binary;
    /// no version comparison is made, but we still surface
    /// the latest `apps.json` entry so the tester can grab
    /// the unsigned IPA via AltStore / SideStore.
    case devBuild(remote: String?, downloadURL: URL?)
    case failed(String)
}

// MARK: - UpdateChecker

/// Fetches the project's AltSource manifest from GitHub
/// Pages and reports whether a newer entry exists in
/// `apps[0].versions[0]`.  The same `apps.json` is what
/// AltStore / SideStore read when the user adds the custom
/// source, so this check is the single source of truth for
/// "is there a newer unsigned IPA available?" — there's no
/// reason to also poll the GitHub Releases API.
///
/// Lives in its own type so the call site can stay a
/// `Button { }` inside the SwiftUI view.
enum UpdateChecker {

    private static let altSourceURL = URL(string:
        "https://darrenintr.github.io/pure-bilibili-rethinking/apps.json"
    )

    /// Public entry point.  Async so the view's `Task { }`
    /// can await the result and update the UI on the main
    /// actor.
    static func check(current: AppVersionInfo) async -> UpdateState {
        guard let altSourceURL else { return .failed(L10n.about.updateFailed) }
        var request = URLRequest(url: altSourceURL)
        request.httpMethod = "GET"
        // Use a recognisable UA so the gh-pages side (and
        // any upstream cache) can tell this is Paladala
        // polling itself.
        request.setValue("Paladala-iOS/\(current.marketingVersion)", forHTTPHeaderField: "User-Agent")
        // GitHub Pages serves `apps.json` as
        // `application/json` (or `text/plain` on edge
        // misconfigurations), so accept both.
        request.setValue("application/json, text/plain;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return .failed(L10n.about.updateFailed)
            }
            let manifest = try JSONDecoder().decode(AltSourceManifest.self, from: data)
            // The single-app case is the only one we ship
            // today (Paladala is the only app in its
            // AltSource), but match by bundleIdentifier to
            // be future-proof if we ever add a sibling.
            guard let app = manifest.apps.first(where: {
                $0.bundleIdentifier == current.bundleId
            }) ?? manifest.apps.first,
                  let latest = app.versions.first,
                  let downloadURL = URL(string: latest.downloadURL) else {
                return .failed(L10n.about.updateFailed)
            }

            let remoteDisplay = "\(latest.version) (\(latest.buildVersion))"
            let localFull = "\(current.marketingVersion).\(current.buildNumber)"
            let remoteFull = "\(latest.version).\(latest.buildVersion)"

            // Local dev builds never match a real release
            // line, so skip the "up to date" branch and
            // surface the latest entry as a devBuild so a
            // tester can grab the unsigned IPA via
            // AltStore / SideStore.
            if current.releaseType.isDevelopment {
                return .devBuild(remote: remoteDisplay, downloadURL: downloadURL)
            }
            switch VersionComparator.compare(localFull, remoteFull) {
            case .orderedAscending:
                return .updateAvailable(remote: remoteDisplay, downloadURL: downloadURL)
            case .orderedSame, .orderedDescending:
                return .upToDate(remote: remoteDisplay)
            }
        } catch {
            bpLog("About: update check failed: \(error.localizedDescription)")
            return .failed(L10n.about.updateFailed)
        }
    }

    /// Subset of the AltSource manifest we care about. See
    /// `scripts/generate_apps_json.py` for the field shape
    /// we actually emit; we only decode the bits the check
    /// needs and ignore the rest.
    ///
    /// `internal` (not `private`) so the test target can
    /// round-trip a sample manifest through the same
    /// `JSONDecoder` to guard against silent schema drift.
    struct AltSourceManifest: Decodable {
        let apps: [AltSourceApp]
    }

    struct AltSourceApp: Decodable {
        let bundleIdentifier: String
        let versions: [AltSourceVersion]
    }

    struct AltSourceVersion: Decodable {
        let version: String
        let buildVersion: String
        let downloadURL: String
    }
}

// MARK: - AppVersionInfo full-version helper

private extension AppVersionInfo {
    /// `marketingVersion + . + buildNumber`, e.g. `0.5.1.2`.
    /// Used as the comparison operand against a remote tag
    /// like `v0.5.1.195` so the version comparator sees the
    /// same number of components on both sides.
    var fullVersion: String {
        "\(marketingVersion).\(buildNumber)"
    }
}

// MARK: - String helpers

private extension String {
    /// Returns the receiver when non-empty, otherwise a
    /// single em-dash.  Used for "—" placeholders so the
    /// About page never renders an empty cell for a
    /// missing Info.plist value.
    var nonEmptyOrDash: String {
        isEmpty ? "—" : self
    }
}
