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
        ScrollView {
            VStack(spacing: PaladalaTheme.Spacing.xxl) {
                headerSection
                identitySection
                updateSection
                footerSection
            }
            .padding(PaladalaTheme.Spacing.l)
        }
        .scrollContentBackground(.hidden)
        .background(PaladalaTheme.canvas)
        .navigationTitle(L10n.about.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast = copyToast {
                copyToastView(toast)
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
        VStack(spacing: PaladalaTheme.Spacing.m) {
            // App icon placeholder
            Rectangle()
                .fill(PaladalaTheme.biliPink)
                .frame(width: 88, height: 88)
                .overlay(
                    Text("BP")
                        .font(.system(size: 36, weight: .black, design: .monospaced))
                        .foregroundStyle(PaladalaTheme.ink)
                )
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }

            Text("Paladala")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundStyle(PaladalaTheme.ink)

            Text("Pure Bilibili · Native iOS")
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.mutedInk)

            Text(version.versionLine)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, PaladalaTheme.Spacing.l)
    }

    private var identitySection: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("構建資訊")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.bottom, PaladalaTheme.Spacing.s)

            // Card
            VStack(spacing: 0) {
                identityRow(label: L10n.about.version, value: version.marketingVersion, showDivider: true)
                identityRow(label: L10n.about.build, value: version.buildNumber, showDivider: true)
                identifierRowStyled
                identityRow(label: L10n.about.releaseType, value: version.releaseTypeDisplay, showDivider: true)
                identityRow(label: L10n.about.channel, value: version.channel.nonEmptyOrDash, showDivider: version.commitShort != nil)

                if let commit = version.commitShort {
                    identityRow(label: L10n.about.commit, value: commit, showDivider: true)
                }

                identityRow(label: L10n.about.buildDate, value: formatDate(version.buildDate), showDivider: true)
                identityRow(label: L10n.about.bundleId, value: version.bundleId, showDivider: false)
            }
            .background(PaladalaTheme.paper)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
            }
            .background {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .offset(x: PaladalaTheme.hardShadowOffset, y: PaladalaTheme.hardShadowOffset)
            }

            // Footer note
            Text("特別辨識號用於精確標識當前構建，反饋問題時附上它可以幫我們快速定位。")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.top, PaladalaTheme.Spacing.s)
        }
    }

    private func identityRow(label: String, value: String, showDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: PaladalaTheme.Spacing.m) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .frame(width: 90, alignment: .leading)

                Text(value)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.vertical, PaladalaTheme.Spacing.m)

            if showDivider {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .frame(height: PaladalaTheme.hairlineWidth)
            }
        }
    }

    private var identifierRowStyled: some View {
        VStack(spacing: 0) {
            Button {
                copyIdentifier()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: PaladalaTheme.Spacing.m) {
                    Text(L10n.about.identifier)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(PaladalaTheme.mutedInk)
                        .frame(width: 90, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.identifierDisplay)
                            .font(PaladalaTheme.FontRole.labelMono)
                            .foregroundStyle(PaladalaTheme.biliPink)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PaladalaTheme.mutedInk)
                }
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.vertical, PaladalaTheme.Spacing.m)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(PaladalaTheme.ink)
                .frame(height: PaladalaTheme.hairlineWidth)
        }
    }

    private var updateSection: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("更新")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.bottom, PaladalaTheme.Spacing.s)

            // Card
            VStack(spacing: 0) {
                // Check for updates button
                Button {
                    checkForUpdates()
                } label: {
                    HStack(spacing: PaladalaTheme.Spacing.m) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(PaladalaTheme.ink)
                            .frame(width: 28)

                        Text(L10n.about.checkForUpdates)
                            .font(PaladalaTheme.FontRole.cardTitle)
                            .foregroundStyle(PaladalaTheme.ink)

                        Spacer()

                        if case .checking = updateState {
                            ProgressView()
                                .tint(PaladalaTheme.ink)
                        }
                    }
                    .padding(.horizontal, PaladalaTheme.Spacing.l)
                    .padding(.vertical, PaladalaTheme.Spacing.m)
                }
                .buttonStyle(.plain)
                .disabled(updateState == .checking)

                // Update result
                if updateState != .idle {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .frame(height: PaladalaTheme.hairlineWidth)

                    updateResultCard
                }
            }
            .background(PaladalaTheme.paper)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
            }
            .background {
                Rectangle()
                    .fill(PaladalaTheme.ink)
                    .offset(x: PaladalaTheme.hardShadowOffset, y: PaladalaTheme.hardShadowOffset)
            }

            // Footer note
            Text(L10n.about.checkSourceHint)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.top, PaladalaTheme.Spacing.s)
        }
    }

    @ViewBuilder
    private var updateResultCard: some View {
        switch updateState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: PaladalaTheme.Spacing.s) {
                ProgressView()
                    .tint(PaladalaTheme.ink)
                Text(L10n.about.checking)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .padding(PaladalaTheme.Spacing.l)
        case .upToDate(let remote):
            HStack(spacing: PaladalaTheme.Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text("\(L10n.about.upToDate) · \(remote)")
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .padding(PaladalaTheme.Spacing.l)
        case .updateAvailable(let remote, let downloadURL):
            updateAvailableCard(remote: remote, downloadURL: downloadURL)
        case .devBuild(let remote, let downloadURL):
            devBuildCard(remote: remote, downloadURL: downloadURL)
        case .failed(let message):
            HStack(spacing: PaladalaTheme.Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
            .padding(PaladalaTheme.Spacing.l)
        }
    }

    private func updateAvailableCard(remote: String, downloadURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: PaladalaTheme.Spacing.m) {
            HStack(spacing: PaladalaTheme.Spacing.s) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(PaladalaTheme.biliPink)
                Text("\(L10n.about.updateAvailable) · \(remote)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.ink)
            }

            installButton(downloadURL: downloadURL)

            installStatusMessages

            if let url = Self.gitHubReleasesURL {
                githubLink(url: url, label: L10n.about.viewOnGitHub)
            }
        }
        .padding(PaladalaTheme.Spacing.l)
    }

    private func devBuildCard(remote: String?, downloadURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: PaladalaTheme.Spacing.m) {
            HStack(spacing: PaladalaTheme.Spacing.s) {
                Image(systemName: "hammer.fill")
                    .foregroundStyle(PaladalaTheme.biliPink)
                Text(L10n.about.devBuild)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.ink)
            }

            if let remote {
                Text(L10n.about.upToDate + " · \(remote)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }

            installButton(downloadURL: downloadURL)

            installStatusMessages

            if let url = Self.gitHubReleasesURL {
                githubLink(url: url, label: L10n.about.viewOnGitHub)
            }
        }
        .padding(PaladalaTheme.Spacing.l)
    }

    @ViewBuilder
    private func installButton(downloadURL: URL?) -> some View {
        if let downloadURL {
            Button {
                Task {
                    await updateManager.installLatestFromStore(downloadURL: downloadURL)
                }
            } label: {
                HStack(spacing: PaladalaTheme.Spacing.s) {
                    if updateManager.installState == .opening {
                        ProgressView()
                            .tint(PaladalaTheme.ink)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                    }
                    Text(installButtonLabel)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(PaladalaTheme.ink)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(PaladalaTheme.biliPink)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }
                .background {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(x: 3, y: 3)
                }
            }
            .buttonStyle(.plain)
            .disabled(updateManager.installState == .opening)
        } else {
            // No downloadURL from apps.json (source not
            // published yet, or the manifest couldn't be
            // parsed). Fall back to the legacy Shortcut
            // install path so the user still has a way
            // forward; this preserves the old behaviour
            // for the empty-source edge case.
            Button {
                Task {
                    await updateManager.downloadAndInstallLatest()
                }
            } label: {
                HStack(spacing: PaladalaTheme.Spacing.s) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(L10n.about.openInAltStore)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(PaladalaTheme.ink)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(PaladalaTheme.biliPink.opacity(0.5))
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }
                .background {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(x: 3, y: 3)
                }
            }
            .buttonStyle(.plain)
            .disabled(updateManager.updateDownloadState == .downloading)
        }
    }

    @ViewBuilder
    private var installStatusMessages: some View {
        switch updateManager.installState {
        case .idle, .opening, .opened:
            // No inline message for the "happy path" — the
            // store app takes over once the URL-scheme
            // handoff completes, so the user is already in
            // the install dialog.
            EmptyView()
        case .noStoreFound:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.about.noStoreDetected)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(PaladalaTheme.mutedInk)
                }
                Text("已為你開啟源頁,喺 AltStore / SideStore 重新整理源後即可一鍵安裝。")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
        }

        // Legacy Shortcut path status — only relevant when
        // the user fell back to it (no downloadURL case
        // above). Kept here so the existing
        // `.failed("请先安装快捷指令")` path still surfaces
        // the setup hint.
        if case .failed(let error) = updateManager.updateDownloadState {
            if error.contains("快捷指令") {
                Button {
                    shortcutManager.checkAndPromptIfNeeded()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                        Text("設定快捷指令")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.biliPink)
                }
            }
        }
    }

    private func githubLink(url: URL, label: String) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                Text(label)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(PaladalaTheme.mutedInk)
        }
    }

    /// Label under the "用 AltStore 安装" / "用 SideStore 安装"
    /// button. Driven by the detected install path: the
    /// button copy tells the user which store we're handing
    /// the install to.
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
            // We don't know which store is installed at
            // this point (canOpenURL is per-tap, not
            // cached), so render a neutral copy that works
            // for either. The button is re-tappable; on
            // first tap the actual store detection runs.
            return L10n.about.openInAltStore
        }
    }

    private var footerSection: some View {
        VStack(spacing: PaladalaTheme.Spacing.xs) {
            Text("Paladala")
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundStyle(PaladalaTheme.ink)
            Text("Pure Bilibili · Native iOS")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PaladalaTheme.Spacing.l)
    }

    // MARK: - Copy toast

    private func copyToastView(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(PaladalaTheme.paper)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(PaladalaTheme.ink)
            .overlay {
                Rectangle()
                    .strokeBorder(PaladalaTheme.paper, lineWidth: 1)
            }
    }

    // MARK: - Actions

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
