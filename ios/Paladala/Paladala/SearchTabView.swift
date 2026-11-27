import SwiftUI

/// Dedicated search tab content, wired to the iOS 26 native
/// `Tab(role: .search)` — the magnifier in the tab bar expands
/// with the system's Liquid Glass morph and auto-focuses this
/// view's `.searchable` field. This is the Apple Music /
/// Podcasts search model: search is its own destination instead
/// of a field embedded in the home feed's nav bar.
struct SearchTabView: View {
    let repository: PaladalaRepository
    var heroNamespace: Namespace.ID? = nil
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = HomeViewModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var accountMid: Int64 { Int64(UserDefaults.standard.integer(forKey: "paladala.account.mid")) }

    /// The keyword the displayed results were actually loaded
    /// with. Pagination compares against it so a half-typed draft
    /// never extends a result set loaded for a different query
    /// (loadMore reads the live `searchQuery` text).
    @State private var submittedQuery = ""

    private func consumePendingSearchQuery() {
        guard !router.pendingSearchQuery.isEmpty else { return }
        model.searchQuery = router.pendingSearchQuery
        router.pendingSearchQuery = ""
        submitSearch()
    }

    private func submitSearch() {
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        submittedQuery = model.searchQuery
        model.clearSuggestions()
        model.category = .search
        Task {
            await model.load(repository: repository, accountMid: accountMid)
            await model.runAllSearch(repository: repository)
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
              count: horizontalSizeClass == .regular ? 3 : 2)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                if !model.searchUsers.isEmpty {
                    SearchUserResultsStrip(users: model.searchUsers)
                        .padding(.bottom, 2)
                }
                if model.videos.isEmpty {
                    ContentUnavailableView(
                        "搜尋",
                        systemImage: "magnifyingglass",
                        description: Text(model.searchQuery.isEmpty
                                          ? "輸入關鍵字搵影片、UP 主"
                                          : "載入中…")
                    )
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                            VideoCard(
                                video: video,
                                repository: repository,
                                heroNamespace: heroNamespace,
                                action: { router.openVideo(video) }
                            )
                            .frame(maxWidth: .infinity)
                            .onAppear {
                                if index >= model.videos.count - 4,
                                   !submittedQuery.isEmpty,
                                   model.searchQuery == submittedQuery {
                                    Task { await model.loadMore(repository: repository, accountMid: accountMid) }
                                }
                            }
                        }
                    }
                    if model.isLoadingMore {
                        ProgressView().padding()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .onAppear {
            consumePendingSearchQuery()
        }
        .onChange(of: router.pendingSearchQuery) { _, _ in
            // `onAppear` never re-fires while the search root stays
            // visible, so keyword deep links arriving mid-session
            // would otherwise sit in `pendingSearchQuery` forever.
            consumePendingSearchQuery()
        }
        .navigationTitle("搜尋")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $model.searchQuery,
            placement: .automatic,
            prompt: "搜尋影片、UP 主"
        )
        .onChange(of: model.searchQuery) { _, query in
            model.searchQueryChanged(query, repository: repository)
        }
        .onSubmit(of: .search) {
            submitSearch()
        }
        .searchSuggestions {
            ForEach(model.searchSuggestions, id: \.displayName) { suggestion in
                Text(suggestion.displayName)
                    .searchCompletion(suggestion.displayName)
            }
        }
    }
}
