import SwiftUI

/// Defers child body evaluation until armed via `.onChange(of: tag)`
/// matching `tag`. Use to avoid paying the cost of a tab's
/// `@StateObject` init on every `TabView` first body evaluation.
///
/// State preservation across tab switches is automatic via SwiftUI's
/// `@State` machinery — once armed, the child view keeps its identity
/// even when the wrapper is re-evaluated (e.g. on a category change).
///
/// PR-A, audit item #5 (lazy `@StateObject` for the 5 tabs).
struct LazyTab<Tag: Hashable, V: View>: View {
    let tag: Tag
    let activeTag: Tag?
    @ViewBuilder let content: () -> V

    @State private var armed: Bool = false

    var body: some View {
        // Always render the content for the active tag without a
        // conditional Group wrapper: the if/else broke propagation of
        // `.navigationTitle` / `.toolbar` / `.searchable` up to the
        // enclosing NavigationStack on iOS 26, leaving the nav bar a
        // blank large-title-height strip. Non-active tabs still defer
        // via the outer `armed` gate using opacity-zero rendering, which
        // keeps preference propagation intact for the visible tab.
        ZStack {
            if armed || activeTag == tag {
                content()
            }
        }
        .onChange(of: activeTag, initial: true) { _, new in
            // `new` is `Tag?`; lift to compare with the non-optional `tag`.
            if let unwrapped = new, unwrapped == tag, !armed {
                armed = true
            }
        }
        .onAppear {
            if !armed, activeTag == nil || activeTag == tag {
                armed = true
            }
        }
    }
}