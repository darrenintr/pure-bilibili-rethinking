import SwiftUI

struct LoginSheet: View {
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var repository: PaladalaRepository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: LoginViewModel

    init() {
        // The live `authStore` arrives via `@EnvironmentObject` from the
        // parent; we hand the model a temporary `AuthStore` here and
        // re-bind in `onAppear` so login completions propagate to the
        // environment-provided singleton.
        let placeholder = AuthStore()
        _model = StateObject(wrappedValue: LoginViewModel(authStore: placeholder))
    }

    var body: some View {
        Group {
            if PaladalaTheme.activeVariant == .iosNative {
                bodyNative
            } else {
                bodyStreet
            }
        }
        .onAppear {
            model.setAuthStore(authStore)
            model.start()
        }
        .onDisappear {
            model.cancel()
        }
        .onChange(of: authStore.activeAccount?.mid) { _, _ in
            if authStore.isLoggedIn {
                // Successful login → unlatch the 401 interceptor so
                // the *next* session-expiry (e.g. SESSDATA rotation
                // in 30 days) can re-pop the sheet. Without this,
                // the latch would stay set forever after the very
                // first 401 burst and subsequent expired sessions
                // would silently fail instead of prompting re-auth.
                repository.apiClient.resetAuthFailureLatch()
                Haptics.success()
                dismiss()
            }
        }
    }

    // MARK: - Street body (existing VStack layout)
    private var bodyStreet: some View {
        NavigationStack {
            VStack(spacing: 22) {
                explanationStreet
                qrCardStreet
                Spacer(minLength: 0)
                footerStreet
            }
            .padding(20)
            .background(PaladalaTheme.canvas)
            .navigationTitle("登入 Bilibili")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") {
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - iOS Native body (Form, grouped)
    //
    // HIG-style modal sheet: `.formStyle(.grouped)` gives the
    // iOS-system look (rounded section cards, hairline separators,
    // page-fitted insets) for free.  The QR card and refresh button
    // use the iOS Native tokens directly so they look at home next
    // to the system chrome.
    private var bodyNative: some View {
        NavigationStack {
            Form {
                Section {
                    explanationNative
                        .listRowBackground(Color.clear)
                        .listRowInsets(
                            EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
                        )
                }
                Section {
                    qrCardNative
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .listRowBackground(Color.clear)
                        .listRowInsets(
                            EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                        )
                }
                Section {
                    footerNative
                        .listRowBackground(Color.clear)
                        .listRowInsets(
                            EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
                        )
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("登入 Bilibili")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("關閉") {
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
        }
    }

    private var explanationStreet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("掃碼登入 Paladala")
                .font(PaladalaTheme.FontRole.displayMedium)
                .foregroundStyle(PaladalaTheme.ink)
                .textCase(.uppercase)
            Text("開啟手機 Bilibili App，掃一掃下方二維碼即可登入。\n登入後可檢視評論、關注動態與個性化首頁。")
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// iOS Native title: SF Pro title style, no uppercase, primary
    /// foreground.  The section is rendered without a `.form` card
    /// background (see `bodyNative` — `listRowBackground(.clear)`)
    /// so the title floats on the page's `systemGroupedBackground`.
    private var explanationNative: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("掃碼登入 Paladala")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            Text("開啟手機 Bilibili App，掃一掃下方二維碼即可登入。登入後可檢視評論、關注動態與個性化首頁。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var qrCardStreet: some View {
        ZStack {
            Rectangle()
                .fill(PaladalaTheme.paper)
                .frame(width: 240, height: 240)
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            PaladalaTheme.ink,
                            lineWidth: PaladalaTheme.borderWidth
                        )
                }
                .background {
                    Rectangle()
                        .fill(PaladalaTheme.ink)
                        .offset(
                            x: PaladalaTheme.hardShadowOffset,
                            y: PaladalaTheme.hardShadowOffset
                        )
                }
            qrCardContent
        }
    }

    /// iOS Native QR card: 240x240 continuous RoundedRectangle(16),
    /// `secondarySystemGroupedBackground` fill (Apple card on a
    /// grouped page), no border, no shadow.  Same inner content as
    /// Street — `qrCardContent` is shared.
    @ViewBuilder
    private var qrCardNative: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .frame(width: 240, height: 240)
            qrCardContent
        }
    }

    /// Inner content driven by `model.state`.  Shared between the
    /// Street and iOS Native QR cards so the user sees the same
    /// QR / progress / error / success states regardless of variant.
    @ViewBuilder
    private var qrCardContent: some View {
        switch model.state {
        case .generating:
            ProgressView()
        case .waiting(let image, _), .scanned(let image, _):
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(16)
        case .expired:
            VStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("二維碼已過期")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(PaladalaTheme.biliPink)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        case .success(let account):
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(PaladalaTheme.biliPink)
                Text(account.name)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var footerStreet: some View {
        VStack(spacing: 12) {
            Text(model.statusText)
                .font(PaladalaTheme.FontRole.bodySmall)
                .foregroundStyle(PaladalaTheme.mutedInk)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    model.regenerate()
                } label: {
                    Label("重新整理二維碼", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PaladalaGlassButtonStyle(materialDesign: .liquidGlass))
            }
        }
    }

    /// iOS Native footer: status text in `.subheadline` + system
    /// `.bordered` refresh button (HIG standard for a secondary
    /// action on a sheet).
    private var footerNative: some View {
        VStack(spacing: 14) {
            Text(model.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                model.regenerate()
            } label: {
                Label("重新整理二維碼", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
        }
    }
}
