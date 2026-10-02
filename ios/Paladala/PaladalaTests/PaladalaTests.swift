import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Paladala

final class PaladalaTests: XCTestCase {
    @MainActor
    func test_playProgressRejectsEmptyBvid() {
        var snapshots: [[PlayProgressEntry]] = []
        let store = makeStore { snapshots.append($0) }

        store.update(bvid: "", currentTime: 1, duration: 100)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(snapshots.isEmpty)
    }

    @MainActor
    func test_playProgressPersistsAtMostOncePerFiveSeconds() {
        let clock = TestClock()
        var snapshots: [[PlayProgressEntry]] = []
        let store = makeStore(clock: clock) { snapshots.append($0) }

        store.update(bvid: "BV1", currentTime: 0, duration: 100)
        for tick in 1...9 {
            clock.advance(by: 0.5)
            store.update(
                bvid: "BV1",
                currentTime: Double(tick) * 0.5,
                duration: 100
            )
        }

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(store.entries["BV1"]?.currentTime, 0)
        XCTAssertEqual(store.lastProgress(for: "BV1")?.currentTime, 4.5)

        clock.advance(by: 0.5)
        store.update(bvid: "BV1", currentTime: 5, duration: 100)

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(store.entries["BV1"]?.currentTime, 5)
    }

    @MainActor
    func test_playProgressForceFlushPersistsLatestPendingSample() {
        let clock = TestClock()
        var snapshots: [[PlayProgressEntry]] = []
        let store = makeStore(clock: clock) { snapshots.append($0) }

        store.update(bvid: "BV1", currentTime: 0, duration: 100)
        clock.advance(by: 1)
        store.update(bvid: "BV1", currentTime: 42, duration: 100)
        XCTAssertEqual(snapshots.count, 1)

        store.flushPending()

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(store.entries["BV1"]?.currentTime, 42)
    }

    @MainActor
    func test_playProgressForceUpdateBypassesCadence() {
        let clock = TestClock()
        var snapshots: [[PlayProgressEntry]] = []
        let store = makeStore(clock: clock) { snapshots.append($0) }

        store.update(bvid: "BV1", currentTime: 0, duration: 100)
        clock.advance(by: 1)
        store.update(
            bvid: "BV1",
            currentTime: 40,
            duration: 100,
            force: true
        )

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(store.entries["BV1"]?.currentTime, 40)
    }

    func test_musicVideosUsesNewlistEndpoint() async throws {
        let session = makeStubSession { request in
            Self.emptyVideoListResponse(for: request)
        }
        defer { session.invalidateAndCancel() }

        let videos = try await BilibiliAPIClient(session: session).musicVideos(page: 2)

        XCTAssertTrue(videos.isEmpty)
        XCTAssertEqual(StubURLProtocol.metrics.lastPath, "/x/web-interface/newlist")
    }


    func test_rateLimitBackoffStopsWhenRequestTaskIsCancelled() async {
        let session = makeStubSession { request in
            Self.response(statusCode: 429, for: request)
        }
        defer { session.invalidateAndCancel() }

        let client = BilibiliAPIClient(session: session)
        let requestTask = Task {
            try await client.musicVideos(page: 1)
        }

        for _ in 0..<100 where StubURLProtocol.metrics.finished == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(StubURLProtocol.metrics.finished, 1)

        // The first 429 response has completed and the client is now in
        // its 1.2-second backoff. Cancellation must stop before a second
        // URLSession request is created.
        requestTask.cancel()
        do {
            _ = try await requestTask.value
            XCTFail("A cancelled backoff must not complete successfully")
        } catch is CancellationError {
            // Expected when cancellation interrupts Task.sleep(for:).
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(StubURLProtocol.metrics.started, 1)
    }

    @MainActor
    func test_requestProvidersExecuteOnMainActor() async throws {
        let session = makeStubSession { request in
            if request.url?.path == "/x/v2/feed/index" {
                return Self.emptyAppFeedResponse(for: request)
            }
            return Self.emptyVideoListResponse(for: request)
        }
        defer { session.invalidateAndCancel() }

        let client = BilibiliAPIClient(session: session)
        let probe = AuthProviderProbe()
        client.cookieProvider = { probe.cookieHeader() }
        client.appConfigProvider = { probe.appConfig() }

        _ = try await client.musicVideos(page: 1)
        _ = try await client.appRecommendedVideos()

        XCTAssertGreaterThanOrEqual(probe.cookieCalls, 2)
        XCTAssertEqual(probe.appConfigCalls, 1)
        XCTAssertTrue(probe.allCallsWereOnMainThread)
    }

    @MainActor
    func test_postSnapshotsCookieAndCSRFBeforeAccountCanChange() async throws {
        let session = makeStubSession { request in
            Self.emptySuccessResponse(for: request)
        }
        defer { session.invalidateAndCancel() }

        let client = BilibiliAPIClient(session: session)
        let provider = RotatingCookieProvider()
        client.cookieProvider = { provider.nextCookie() }

        try await client.addCoins(aid: 1)

        let metrics = StubURLProtocol.metrics
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(metrics.lastCookie, "bili_jct=token=value; SESSDATA=account-a")
        XCTAssertTrue(metrics.lastBody?.contains("csrf=token%3Dvalue") == true)
    }

    func test_sessionExpiryCallbackIsLatchedAndDeliveredOnMainActor() async {
        let session = makeStubSession { request in
            Self.response(statusCode: 401, for: request)
        }
        defer { session.invalidateAndCancel() }

        let client = BilibiliAPIClient(session: session)
        let probe = AuthFailureProbe()
        client.onAuthFailure = {
            probe.recordCallback(isMainThread: Thread.isMainThread)
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try? await client.musicVideos(page: 1)
                }
            }
        }

        for _ in 0..<100 where probe.callCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertTrue(probe.allCallbacksWereOnMainThread)

        client.resetAuthFailureLatch()
        _ = try? await client.musicVideos(page: 1)
        for _ in 0..<100 where probe.callCount < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(probe.callCount, 2)
    }

    func test_appErrorDescriptorIgnoresCancellation() {
        XCTAssertNil(AppErrorDescriptor.describe(CancellationError()))
        XCTAssertNil(AppErrorDescriptor.describe(URLError(.cancelled)))
    }

    func test_appErrorDescriptorMapsNetworkAndAuthenticationErrors() throws {
        let network = try XCTUnwrap(
            AppErrorDescriptor.describe(URLError(.notConnectedToInternet))
        )
        XCTAssertEqual(network.kind, .network)
        XCTAssertTrue(network.isRetryable)
        XCTAssertEqual(network.message, "当前没有网络连接，请联网后重试。")

        let authentication = try XCTUnwrap(
            AppErrorDescriptor.describe(BilibiliAPIError.sessionExpired)
        )
        XCTAssertEqual(authentication.kind, .authentication)
        XCTAssertFalse(authentication.isRetryable)
    }

    @MainActor
    func test_appErrorCenterDeduplicatesAndAdvancesQueuedErrors() {
        var now = Date(timeIntervalSince1970: 1_000)
        let center = AppErrorCenter(
            deduplicationInterval: 10,
            now: { now }
        )

        center.present(URLError(.timedOut), context: "home.refresh")
        let firstID = center.current?.id
        center.present(URLError(.timedOut), context: "home.refresh")
        center.present(URLError(.notConnectedToInternet), context: "music.refresh")

        XCTAssertEqual(center.current?.id, firstID)
        center.dismiss()
        XCTAssertEqual(center.current?.descriptor.kind, .network)
        XCTAssertEqual(center.current?.context, "music.refresh")

        now.addTimeInterval(11)
        center.dismiss()
        center.present(URLError(.timedOut), context: "home.refresh")
        XCTAssertNotNil(center.current)
    }

    @MainActor
    func test_appErrorCenterRunsRecoveryAfterDismissingAlert() {
        let center = AppErrorCenter()
        var recovered = false
        center.present(
            URLError(.timedOut),
            context: "video.load",
            recoveryLabel: "重试",
            recovery: { recovered = true }
        )

        center.recover()

        XCTAssertTrue(recovered)
        XCTAssertNil(center.current)
    }

    @MainActor
    func test_loadStateCancellationPreservesExistingValueAndHasNoError() async {
        let state = LoadState(value: [1, 2, 3])

        await state.load({ throw CancellationError() }, errorText: "不应显示")

        XCTAssertEqual(state.value, [1, 2, 3])
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.isLoading)
    }

    func test_lyricTrackFindsLastLineAtOrBeforePlaybackTime() {
        let track = BiliLyricTrack(
            lines: [
                BiliLyricLine(startTime: 2, text: "First", isMetadata: false, ordinal: 0),
                BiliLyricLine(startTime: 8, text: "Second", isMetadata: false, ordinal: 1),
                BiliLyricLine(startTime: 15, text: "Third", isMetadata: false, ordinal: 2),
            ],
            language: "zh-CN"
        )

        XCTAssertEqual(track.index(at: 0), 0)
        XCTAssertEqual(track.index(at: 2), 0)
        XCTAssertEqual(track.index(at: 14.999), 1)
        XCTAssertEqual(track.index(at: 15), 2)
        XCTAssertEqual(track.index(at: 999), 2)
        XCTAssertEqual(track.index(at: .nan), 0)
    }

    func test_lyricParserPreservesSourceOrderForEqualTimestamps() throws {
        let raw = #"{"body":[{"from":10,"to":11,"content":"First ten"},{"from":5,"to":6,"content":"Five"},{"from":10,"to":12,"content":"Second ten"}]}"#
        let track = try XCTUnwrap(BiliLyricParser.parse(text: raw, language: "en"))

        XCTAssertEqual(track.lines.map(\.text), ["Five", "First ten", "Second ten"])
        XCTAssertEqual(track.lines.map(\.ordinal), [1, 0, 2])
        XCTAssertEqual(track.index(at: 10), 2)
    }

    private func makeStubSession(
        delay: TimeInterval = 0,
        handler: @escaping StubURLProtocol.Handler
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.configure(delay: delay, handler: handler)
        return URLSession(configuration: configuration)
    }

    private static func emptyAppFeedResponse(
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let (response, _) = response(statusCode: 200, for: request)
        return (response, Data(#"{"code":0,"message":"OK","data":{"items":[]}}"#.utf8))
    }

    private static func emptySuccessResponse(
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let (response, _) = response(statusCode: 200, for: request)
        return (response, Data(#"{"code":0,"message":"OK","data":{}}"#.utf8))
    }

    private static func emptyVideoListResponse(
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let (response, _) = response(statusCode: 200, for: request)
        let body = Data(#"{"code":0,"message":"OK","data":{"archives":[]}}"#.utf8)
        return (response, body)
    }

    private static func response(
        statusCode: Int,
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data())
    }

    @MainActor
    private func makeStore(
        clock: TestClock = TestClock(),
        persistenceObserver: @escaping @MainActor ([PlayProgressEntry]) -> Void
    ) -> PlayProgressStore {
        PlayProgressStore(
            initialEntries: [:],
            nowProvider: { clock.now },
            persistenceObserver: persistenceObserver,
            schedulesDelayedFlushes: false,
            observesLifecycle: false
        )
    }
}

@MainActor
private final class TestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}


@MainActor
private final class AuthProviderProbe {
    private(set) var cookieCalls = 0
    private(set) var appConfigCalls = 0
    private(set) var allCallsWereOnMainThread = true

    func cookieHeader() -> String? {
        cookieCalls += 1
        allCallsWereOnMainThread = allCallsWereOnMainThread && Thread.isMainThread
        return nil
    }

    func appConfig() -> BiliAppConfig? {
        appConfigCalls += 1
        allCallsWereOnMainThread = allCallsWereOnMainThread && Thread.isMainThread
        return BiliAppConfig(buvid3: nil, mid: 0, csrf: nil)
    }
}

@MainActor
private final class RotatingCookieProvider {
    private(set) var callCount = 0

    func nextCookie() -> String? {
        callCount += 1
        if callCount == 1 {
            return "bili_jct=token=value; SESSDATA=account-a"
        }
        return "bili_jct=other; SESSDATA=account-b"
    }
}

private final class AuthFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0
    private var callbacksStayedOnMainThread = true

    var callCount: Int {
        lock.withLock { callbacks }
    }

    var allCallbacksWereOnMainThread: Bool {
        lock.withLock { callbacksStayedOnMainThread }
    }

    func recordCallback(isMainThread: Bool) {
        lock.withLock {
            callbacks += 1
            callbacksStayedOnMainThread = callbacksStayedOnMainThread && isMainThread
        }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

    private struct State {
        var delay: TimeInterval = 0
        var handler: Handler?
        var lastPath: String?
        var lastCookie: String?
        var lastBody: String?
        var started = 0
        var finished = 0
        var cancelled = 0
    }

    nonisolated(unsafe) private static var state = State()
    private static let lock = NSLock()
    private var workItem: DispatchWorkItem?

    static var metrics: (
        lastPath: String?,
        lastCookie: String?,
        lastBody: String?,
        started: Int,
        finished: Int,
        cancelled: Int
    ) {
        lock.withLock {
            (
                lastPath: state.lastPath,
                lastCookie: state.lastCookie,
                lastBody: state.lastBody,
                started: state.started,
                finished: state.finished,
                cancelled: state.cancelled
            )
        }
    }

    static func configure(delay: TimeInterval, handler: @escaping Handler) {
        lock.withLock {
            state = State(delay: delay, handler: handler)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let configuration = Self.lock.withLock {
            Self.state.lastPath = request.url?.path
            Self.state.lastCookie = request.value(forHTTPHeaderField: "Cookie")
            Self.state.lastBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            Self.state.started += 1
            return (Self.state.delay, Self.state.handler)
        }
        guard let handler = configuration.1 else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let urlProtocol = self
        let item = DispatchWorkItem {
            let (response, data) = handler(urlProtocol.request)
            let isCancelled = Self.lock.withLock { urlProtocol.workItem?.isCancelled == true }
            if isCancelled { return }
            Self.lock.withLock { Self.state.finished += 1 }
            urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
            urlProtocol.client?.urlProtocol(urlProtocol, didLoad: data)
            urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
        }
        workItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + configuration.0, execute: item)
    }

    override func stopLoading() {
        guard let workItem, !workItem.isCancelled else { return }
        workItem.cancel()
        Self.lock.withLock { Self.state.cancelled += 1 }
    }
}
