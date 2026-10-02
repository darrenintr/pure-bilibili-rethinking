import XCTest
@testable import Paladala

/// Tests for `LoadState<T>` — the load/error/empty helper that
/// 20+ ViewModels in `AccountContentViews` /
/// `ViewModels.swift` / `UPProfileView.swift` were re-implementing
/// by hand.  The bug surface that motivated the extraction:
///
/// - `HistoryListViewModel.load` set `items = []` and
///   `nextCursor = nil` on the catch branch — easy to forget
///   one of those fields if a new sibling state field is added.
/// - `ShortVideoFeedViewModel.load` had `guard !isLoading else
///   { return }` but the others didn't — so two parallel taps
///   could race the same `load()` and one would overwrite the
///   other's `videos` with a stale result.
///
/// `LoadState` codifies both invariants so future regressions
/// are caught by `XCTestCase` instead of by user-visible flicker.
@MainActor
final class LoadStateTests: XCTestCase {

    func test_initialState_isEmpty() {
        let state = LoadState<[Int]>()
        XCTAssertNil(state.value)
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.isLoadingMore)
        XCTAssertNil(state.errorMessage)
    }

    func test_load_success_assignsValue_andClearsError() async {
        let state = LoadState<[Int]>()
        await state.load(
            { [1, 2, 3] },
            errorText: "載入失敗"
        )
        XCTAssertEqual(state.value, [1, 2, 3])
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }

    func test_load_error_setsMessage_andClearsValue() async {
        let state = LoadState<[Int]>(value: [99])
        await state.load(
            { throw TestError.boom },
            errorText: "載入失敗"
        )
        XCTAssertNil(state.value, "error path must clear the previous value")
        XCTAssertEqual(state.errorMessage, "載入失敗")
        XCTAssertFalse(state.isLoading)
    }

    func test_load_clearsError_atTop() async {
        // Set up an error state from a prior call.
        let state = LoadState<[Int]>()
        await state.load(
            { throw TestError.boom },
            errorText: "first failure"
        )
        XCTAssertEqual(state.errorMessage, "first failure")

        // A successful reload must clear the prior error and assign.
        await state.load(
            { [42] },
            errorText: "second failure"
        )
        XCTAssertEqual(state.value, [42])
        XCTAssertNil(state.errorMessage)
    }

    func test_load_concurrentCalls_secondIsNoOp() async {
        // Two parallel loads on the same LoadState: the second
        // must short-circuit (mirrors `ShortVideoFeedViewModel`'s
        // `guard !isLoading else { return }`).  We assert by
        // observing `workInvocations` — the work closure must
        // not be called twice.
        let state = LoadState<[Int]>()
        var workInvocations = 0
        let work: () async throws -> [Int] = {
            workInvocations += 1
            // Yield so the second load has a chance to enter
            // while the first is still inside its critical
            // section.
            await Task.yield()
            return [1]
        }
        async let first: Void = state.load(work, errorText: "err")
        async let second: Void = state.load(work, errorText: "err")
        _ = await (first, second)
        XCTAssertEqual(workInvocations, 1, "second load must short-circuit while isLoading")
        XCTAssertEqual(state.value, [1])
    }

    func test_loadMore_appendsResult_onSuccess() async {
        let state = LoadState<[Int]>(value: [1, 2])
        await state.loadMore(
            { [3, 4] },
            append: { existing, next in existing + next },
            errorText: "載入更多失敗"
        )
        XCTAssertEqual(state.value, [1, 2, 3, 4])
        XCTAssertFalse(state.isLoadingMore)
        XCTAssertNil(state.errorMessage)
    }

    func test_loadMore_preservesValue_onFailure() async {
        // The original `HistoryListViewModel.loadMore` only set
        // `errorMessage` on failure — the existing items stayed
        // on screen so the user could see the inline error
        // banner without losing the partial result.  Codify that
        // here.
        let state = LoadState<[Int]>(value: [1, 2])
        await state.loadMore(
            { throw TestError.boom },
            append: { existing, next in existing + next },
            errorText: "載入更多失敗"
        )
        XCTAssertEqual(state.value, [1, 2], "loadMore failure must NOT clear existing value")
        XCTAssertEqual(state.errorMessage, "載入更多失敗")
        XCTAssertFalse(state.isLoadingMore)
    }

    func test_loadMore_noOp_whenValueIsNil() async {
        // Without a first page there is nothing to append to —
        // the original `HistoryListViewModel.loadMore` had a
        // `let cursor = nextCursor else { return }` guard that
        // served the same purpose.  `LoadState` enforces this
        // by skipping when `value == nil`.
        let state = LoadState<[Int]>()
        var workInvocations = 0
        await state.loadMore(
            {
                workInvocations += 1
                return [1]
            },
            append: { existing, next in existing + next },
            errorText: "err"
        )
        XCTAssertEqual(workInvocations, 0)
        XCTAssertNil(state.value)
    }

    func test_loadMore_noOp_whenLoading() async {
        // Two parallel calls — one load() and one loadMore() —
        // should not both fire their work closures.  loadMore's
        // `!isLoading` guard mirrors `HistoryListViewModel`'s
        // `guard !isLoading, !isLoadingMore, hasMore, ...`.
        let state = LoadState<[Int]>(value: [1])
        var loadMoreInvocations = 0
        async let first: Void = state.load({ [2] }, errorText: "e")
        async let second: Void = state.loadMore(
            {
                loadMoreInvocations += 1
                return [3]
            },
            append: { existing, next in existing + next },
            errorText: "e"
        )
        _ = await (first, second)
        XCTAssertEqual(loadMoreInvocations, 0)
    }

    func test_reset_clearsEverything() async {
        let state = LoadState<[Int]>()
        await state.load({ [1] }, errorText: "e")
        XCTAssertEqual(state.value, [1])
        state.reset()
        XCTAssertNil(state.value)
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.isLoadingMore)
        XCTAssertNil(state.errorMessage)
    }

    private enum TestError: Error {
        case boom
    }
}