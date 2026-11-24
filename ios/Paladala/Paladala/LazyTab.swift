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
        Group {
            // iOS 26's `TabView` mounts only the selected tab's body
            // and neither `.onChange(initial:)` nor `.onAppear` is
            // guaranteed to fire for the tag already selected at
            // first evaluation — gating purely on `armed` left the
            // home tab an `EmptyView` until the user switched away
            // and back. `armed` now only keeps a once-visited tab's
            // `@StateObject` alive while it's off-screen.
            if armed || activeTag == tag {
                content()
            } else {
                EmptyView()
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