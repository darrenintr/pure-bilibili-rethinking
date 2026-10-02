//
//  ShortcutManager.swift
//  Paladala
//
//  Manages Apple Shortcuts integration for one-tap IPA installation.
//  On first launch, prompts the user to install a dedicated Shortcut
//  that can download and install IPAs via SideStore. On subsequent
//  update checks, the app passes the IPA URL to the Shortcut via
//  x-callback-url, and the Shortcut handles the entire flow.
//
//  Shortcut flow:
//    1. App calls: shortcuts://x-callback-url/run-shortcut?name=安装Paladala&input=<IPA_URL>
//    2. Shortcut downloads IPA to iCloud Drive or local Files
//    3. Shortcut calls SideStore via sidestore://install?url=<local_path>
//    4. SideStore installs the IPA
//

import Foundation
import SwiftUI

/// Manages the lifecycle of the "安装Paladala" Shortcut:
/// installation prompt, status tracking, and invocation.
@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()

    /// The canonical name of the Shortcut the user must install.
    /// This must match the name in the .shortcut file exactly.
    static let shortcutName = "安裝Paladala"

    /// UserDefaults key tracking whether the user has completed
    /// the initial Shortcut installation flow.
    private static let hasInstalledShortcutKey = "hasInstalledPaladalaShortcut"

    @Published var hasInstalledShortcut: Bool {
        didSet {
            UserDefaults.standard.set(hasInstalledShortcut, forKey: Self.hasInstalledShortcutKey)
        }
    }

    @Published var showInstallPrompt: Bool = false

    private init() {
        self.hasInstalledShortcut = UserDefaults.standard.bool(forKey: Self.hasInstalledShortcutKey)
    }

    // MARK: - Public API

    /// Check if we should show the first-run install prompt.
    /// Call this on app launch or when the user first taps "检查更新".
    func checkAndPromptIfNeeded() {
        if !hasInstalledShortcut {
            showInstallPrompt = true
        }
    }

    /// Mark that the user has completed the Shortcut installation.
    /// Call this when the user taps "我已安装" on the prompt.
    func markShortcutInstalled() {
        hasInstalledShortcut = true
        showInstallPrompt = false
    }

    /// Invoke the installed Shortcut to download and install an IPA.
    /// - Parameter ipaURL: The direct download URL for the unsigned IPA
    /// - Returns: `true` if the Shortcut URL was opened successfully, `false` otherwise
    @discardableResult
    func installIPA(from ipaURL: URL) -> Bool {
        guard hasInstalledShortcut else {
            bpLog("ShortcutManager: cannot invoke shortcut, user hasn't installed it yet")
            return false
        }

        // Construct the x-callback-url to run the Shortcut with the IPA URL as input
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: Self.shortcutName),
            URLQueryItem(name: "input", value: ipaURL.absoluteString)
        ]

        guard let shortcutURL = components?.url else {
            bpLog("ShortcutManager: failed to construct shortcut URL")
            return false
        }

        guard UIApplication.shared.canOpenURL(shortcutURL) else {
            bpLog("ShortcutManager: cannot open shortcuts:// URL scheme")
            return false
        }

        bpLog("ShortcutManager: invoking shortcut with IPA URL: \(ipaURL.absoluteString)")
        UIApplication.shared.open(shortcutURL) { success in
            if success {
                bpLog("ShortcutManager: shortcut invoked successfully")
            } else {
                bpLog("ShortcutManager: failed to invoke shortcut")
            }
        }

        return true
    }

    /// Open the Shortcuts app to the gallery or a pre-built .shortcut file
    /// so the user can install the "安装Paladala" Shortcut.
    func openShortcutsApp() {
        // Strategy 1: if we bundle a .shortcut file and host it on GitHub,
        // open that URL directly so the user can tap "Add Shortcut"
        if let shortcutURL = URL(string: "https://github.com/darrenintr/pure-bilibili-rethinking/raw/main/shortcuts/安裝Paladala.shortcut") {
            UIApplication.shared.open(shortcutURL)
            return
        }

        // Strategy 2: fallback to opening the Shortcuts app home screen
        if let shortcutsAppURL = URL(string: "shortcuts://"),
           UIApplication.shared.canOpenURL(shortcutsAppURL) {
            UIApplication.shared.open(shortcutsAppURL)
        }
    }
}

// MARK: - Shortcut Install Prompt View

/// Full-screen modal that guides the user through installing the
/// "安装Paladala" Shortcut. Shown on first launch or first update check.
struct ShortcutInstallPromptView: View {
    @ObservedObject var shortcutManager = ShortcutManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PaladalaTheme.Spacing.xl) {
                    headerSection
                    instructionsSection
                    actionButtons
                }
                .padding(PaladalaTheme.Spacing.l)
            }
            .scrollContentBackground(.hidden)
            .background(PaladalaTheme.canvas)
            .navigationTitle("一鍵更新設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(PaladalaTheme.ink)
                    }
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: PaladalaTheme.Spacing.m) {
            Image(systemName: "app.badge.checkmark.fill")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(PaladalaTheme.biliPink)
                .padding(.top, PaladalaTheme.Spacing.l)

            Text("安裝更新快捷指令")
                .font(.system(size: 24, weight: .black, design: .monospaced))
                .foregroundStyle(PaladalaTheme.ink)

            Text("一次設定，永久使用")
                .font(PaladalaTheme.FontRole.labelMono)
                .foregroundStyle(PaladalaTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
    }

    private var instructionsSection: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("操作步驟")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, PaladalaTheme.Spacing.l)
            .padding(.bottom, PaladalaTheme.Spacing.s)

            // Card
            VStack(alignment: .leading, spacing: PaladalaTheme.Spacing.l) {
                instructionStep(
                    number: "1",
                    title: "下載快捷指令",
                    description: "點選下方按鈕，Safari 會開啟快捷指令安裝頁面"
                )

                Divider()
                    .background(PaladalaTheme.ink)

                instructionStep(
                    number: "2",
                    title: "新增到快捷指令庫",
                    description: "在開啟的頁面中，向下滾動並點選「新增快捷指令」"
                )

                Divider()
                    .background(PaladalaTheme.ink)

                instructionStep(
                    number: "3",
                    title: "完成設定",
                    description: "安裝完成後，返回 Paladala 點選「我已安裝」"
                )
            }
            .padding(PaladalaTheme.Spacing.l)
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
            Text("安裝後，每次檢查更新時會自動呼叫快捷指令完成下載和安裝，無需手動操作。")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(PaladalaTheme.mutedInk)
                .padding(.horizontal, PaladalaTheme.Spacing.l)
                .padding(.top, PaladalaTheme.Spacing.s)
        }
    }

    private func instructionStep(number: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: PaladalaTheme.Spacing.m) {
            Text(number)
                .font(.system(size: 18, weight: .black, design: .monospaced))
                .foregroundStyle(PaladalaTheme.paper)
                .frame(width: 32, height: 32)
                .background(PaladalaTheme.biliPink)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .default))
                    .foregroundStyle(PaladalaTheme.ink)

                Text(description)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: PaladalaTheme.Spacing.m) {
            // Primary: open Shortcuts app to install
            Button {
                shortcutManager.openShortcutsApp()
            } label: {
                HStack(spacing: PaladalaTheme.Spacing.s) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text("下載快捷指令")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(PaladalaTheme.ink)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(PaladalaTheme.biliPink)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }
                .background {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(x: 4, y: 4)
                }
            }
            .buttonStyle(.plain)

            // Secondary: mark as installed
            Button {
                shortcutManager.markShortcutInstalled()
                dismiss()
            } label: {
                HStack(spacing: PaladalaTheme.Spacing.s) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .bold))
                    Text("我已安裝")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(PaladalaTheme.ink)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(PaladalaTheme.paper)
                .overlay {
                    Rectangle()
                        .strokeBorder(PaladalaTheme.ink, lineWidth: PaladalaTheme.borderWidth)
                }
            }
            .buttonStyle(.plain)

            // Tertiary: skip for now
            Button {
                dismiss()
            } label: {
                Text("暫時跳過")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PaladalaTheme.mutedInk)
            }
        }
        .padding(.top, PaladalaTheme.Spacing.m)
    }
}
