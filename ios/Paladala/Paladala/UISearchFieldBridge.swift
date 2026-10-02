import SwiftUI
import UIKit

/// `UISearchBar` wrapped for SwiftUI with Street Minimal chrome.
///
/// SwiftUI's `.searchable` modifier renders a private
/// `UISearchBar` whose background and inner text field are
/// not exposed through `UISearchBar.appearance()` on iOS 26.
/// The default surface is a round-cornered glass capsule
/// that doesn't sit flush with the rest of the Street
/// chrome (paper nav bar, ink borders, 0 corner radius).
///
/// This bridge owns a regular `UISearchBar` and styles every
/// visible surface directly, so the bar becomes a flat paper
/// rect with a 1.5pt ink border and no rounding — matching
/// `PaladalaTheme` exactly.  The leading magnifier is
/// replaced with a tinted SF Symbol so the iconography stays
/// consistent with the rest of the app.
///
/// ## Differences vs `.searchable`
///
/// - **No `.searchSuggestions` integration.**  The SwiftUI
///   suggestion pipeline (`.searchSuggestions { … }` +
///   `.searchCompletion(_:)`) only works with the
///   system-rendered search controller.  Sites that need
///   suggestions should render their own SwiftUI list
///   beside or below the bridge and feed `text` from the
///   `onQueryChanged` callback.  Out of scope for this
///   first pass.
///
/// - **In-content placement.**  This bridge is a plain
///   SwiftUI view, not a navigation-bar drawer.  Place it
///   at the top of the parent view's body.  Scroll-driven
///   show/hide (the system behavior with
///   `.navigationBarDrawer`) is intentionally not
///   implemented — the bar stays visible so the user can
///   always tap back into it.  Add `ScrollViewReader` +
///   a `coordinateSpace` proxy if you want a hide-on-scroll
///   affordance later.
struct UISearchFieldBridge: UIViewRepresentable {
    @Binding var text: String
    let prompt: String
    let onSubmit: () -> Void
    let onQueryChanged: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onQueryChanged: onQueryChanged
        )
    }

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.delegate = context.coordinator
        bar.searchBarStyle = .minimal
        bar.placeholder = prompt
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.returnKeyType = .search
        bar.backgroundColor = .clear
        // The outer bar stays transparent so the parent's
        // paper background (the nav bar or a VStack) shows
        // through — the visible chrome lives on the inner
        // text field below.
        applyStreetChrome(to: bar)
        return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
        if bar.text != text {
            bar.text = text
        }
        if bar.placeholder != prompt {
            bar.placeholder = prompt
        }
        // Re-apply chrome in case the active design variant
        // flipped at runtime (PaladalaTheme tokens are
        // computed off `activeVariant`; the bar's stored
        // UIColors don't auto-track that change).
        applyStreetChrome(to: bar)
    }

    /// Centralised chrome styling so `makeUIView` and
    /// `updateUIView` stay in lockstep.  Reads from
    /// `PaladalaTheme` at call time, so a runtime toggle of
    /// `DesignVariant` updates the bar on the next render.
    ///
    /// - Street: hard-edged paper background, 1.5pt ink border,
    ///   no corner radius, custom SF-Symbol magnifier — matches
    ///   the rest of the Street chrome.
    /// - iOS Native: skip our custom chrome entirely.  The
    ///   `.minimal` `UISearchBar` style already gives a soft
    ///   rounded field with the system tint; layering our own
    ///   ink border + zero radius on top of it produces a
    ///   visibly square bar that doesn't match HIG.  We still
    ///   swap the magnifier for a tinted SF Symbol so the
    ///   iconography is consistent with the rest of the app.
    private func applyStreetChrome(to bar: UISearchBar) {
        let field = bar.searchTextField
        if PaladalaTheme.usesNativeLayout {
            // System default chrome — `.minimal` already
            // provides a tinted, rounded field.
            field.backgroundColor = nil
            field.textColor = nil
            field.tintColor = nil
            field.attributedPlaceholder = NSAttributedString(
                string: prompt,
                attributes: [.foregroundColor: UIColor.secondaryLabel]
            )
            field.borderStyle = .none
            field.layer.borderColor = nil
            field.layer.borderWidth = 0
            field.layer.cornerRadius = 0
            field.layer.masksToBounds = false
        } else {
            field.backgroundColor = UIColor(PaladalaTheme.paper)
            field.textColor = UIColor(PaladalaTheme.ink)
            field.tintColor = UIColor(PaladalaTheme.biliPink)
            field.attributedPlaceholder = NSAttributedString(
                string: prompt,
                attributes: [
                    .foregroundColor: UIColor(PaladalaTheme.mutedInk)
                ]
            )
            field.borderStyle = .none
            field.layer.borderColor = UIColor(PaladalaTheme.ink).cgColor
            field.layer.borderWidth = PaladalaTheme.borderWidth
            field.layer.cornerRadius = 0
            field.layer.masksToBounds = true
        }
        // Swap the default left-view icon for a tinted
        // SF Symbol so the bar matches the rest of the
        // app's iconography.
        if let icon = field.leftView as? UIImageView {
            icon.tintColor = UIColor(PaladalaTheme.mutedInk)
            icon.image = UIImage(systemName: "magnifyingglass")
        }
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onQueryChanged: (String) -> Void

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onQueryChanged: @escaping (String) -> Void
        ) {
            self._text = text
            self.onSubmit = onSubmit
            self.onQueryChanged = onQueryChanged
        }

        func searchBar(
            _ searchBar: UISearchBar,
            textDidChange searchText: String
        ) {
            text = searchText
            onQueryChanged(searchText)
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
            onSubmit()
        }
    }
}
