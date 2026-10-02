import AVFoundation
import Foundation
import Network
import XCTest
@testable import Paladala

@MainActor
final class PlaybackAndDesignTests: XCTestCase {
    func testExistingInstallsMigrateToExpressiveOnce() {
        XCTAssertEqual(DesignVariant.storedChoice(rawValue: "streetRedesign", migrationVersion: 0), .expressive)
        XCTAssertEqual(DesignVariant.storedChoice(rawValue: nil, migrationVersion: 0), .expressive)
        XCTAssertEqual(DesignVariant.storedChoice(rawValue: "iosNative", migrationVersion: 1), .iosNative)
        XCTAssertTrue(DesignVariant.userFacingCases.contains(.expressive))
    }

    func testAnUnknownTimelineCannotReportVideoCompletion() {
        XCTAssertFalse(PlayerController.hasReachedEnd(currentTime: 0, duration: 0))
        XCTAssertFalse(PlayerController.hasReachedEnd(currentTime: 0, duration: .nan))
        XCTAssertFalse(PlayerController.hasReachedEnd(currentTime: 1, duration: 60))
        XCTAssertTrue(PlayerController.hasReachedEnd(currentTime: 60, duration: 60))
    }

    func testVideoOnlyPlaybackDoesNotProbeAMissingAudioPlaylist() {
        XCTAssertEqual(PlayerController.proxyEndpointPaths(hasAudio: false), ["/playlist.m3u8", "/video.m3u8"])
        XCTAssertEqual(PlayerController.proxyEndpointPaths(hasAudio: true), ["/playlist.m3u8", "/video.m3u8", "/audio.m3u8"])
    }

    func testDASHDoesNotBindAnEmptyPlayerItemDuringPreparation() throws {
        let proxy = LocalHLSProxyServer(port: 0)
        let controller = PlayerController(playback: playback(url: URL(string: "http://127.0.0.1:9/video.m4s")!), proxyServer: proxy)
        defer { controller.tearDown(); proxy.stop() }
        XCTAssertEqual(controller.playbackState, .preparing)
        XCTAssertNil(controller.player.currentItem)
        controller.play()
        XCTAssertNil(controller.player.currentItem)
    }

    func testVideoOnlyDASHAdvancesToTheEndAndReplays() async throws {
        try await assertDASHPlayback(withAudio: false)
    }

    func testVideoAndAudioDASHAdvancesToTheEndAndReplays() async throws {
        try await assertDASHPlayback(withAudio: true)
    }

    private func assertDASHPlayback(withAudio: Bool) async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-video", withExtension: "m4s"))
        let upstream = try RangeFixtureServer(data: Data(contentsOf: fixture))
        defer { upstream.stop() }
        try await waitUntil { upstream.port != nil }
        let port = try XCTUnwrap(upstream.port)
        var audioUpstream: RangeFixtureServer?
        if withAudio {
            let audioFixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-audio", withExtension: "m4s"))
            audioUpstream = try RangeFixtureServer(data: Data(contentsOf: audioFixture))
            try await waitUntil { audioUpstream?.port != nil }
        }
        defer { audioUpstream?.stop() }
        let audioURL = audioUpstream?.port.flatMap { URL(string: "http://127.0.0.1:\($0)/audio.m4s") }
        let proxy = LocalHLSProxyServer(port: 0)
        let controller = PlayerController(playback: playback(url: URL(string: "http://127.0.0.1:\(port)/video.m4s")!, audioURL: audioURL), proxyServer: proxy)
        defer { controller.tearDown(); proxy.stop() }

        try await waitUntil(seconds: 15) {
            controller.player.currentItem?.status == .readyToPlay || controller.playerError != nil
        }
        XCTAssertNil(controller.playerError)
        let item = try XCTUnwrap(controller.player.currentItem)
        XCTAssertEqual(item.duration.seconds, 4, accuracy: 0.15)
        if withAudio {
            let audioTracks = try await item.asset.loadTracks(withMediaType: .audio)
            XCTAssertFalse(audioTracks.isEmpty, "The DASH audio rendition must reach AVPlayer")
        }
        try await waitUntil { controller.player.currentTime().seconds > 0.25 }
        try await waitUntil(seconds: 8) {
            PlayerController.hasReachedEnd(currentTime: controller.player.currentTime().seconds, duration: item.duration.seconds)
        }
        controller.play()
        try await waitUntil {
            controller.player.currentTime().seconds < 1 && controller.player.rate > 0
        }
        XCTAssertNil(controller.playerError)
    }

    private func playback(url: URL, audioURL: URL? = nil) -> BiliPlayback {
        let video = BiliDashSource.Track(
            baseURL: url, backupURLs: [], codecs: "avc1.4D400A", bandwidth: 500_000,
            mimeType: "video/mp4", initializationRange: .init(offset: 0, length: 777),
            indexRange: .init(offset: 777, length: 88), mediaStartOffset: 865,
            totalDuration: 4, width: 160, height: 90
        )
        let audio = audioURL.map {
            BiliDashSource.Track(baseURL: $0, backupURLs: [], codecs: "mp4a.40.2", bandwidth: 96_000,
                                 mimeType: "audio/mp4", initializationRange: .init(offset: 0, length: 733),
                                 indexRange: .init(offset: 733, length: 52), mediaStartOffset: 785,
                                 totalDuration: 4.021333, width: nil, height: nil)
        }
        return BiliPlayback(dash: BiliDashSource(video: video, audio: audio), fallbackURL: nil,
                            referer: URL(string: "https://www.bilibili.com/")!)
    }

    private func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Playback condition timed out")
                throw NSError(domain: "PlaybackFixture", code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A local byte-range upstream. Exercises real HTTP, SIDX preparation,
/// manifest generation and AVPlayer without depending on Bilibili's CDN.
private final class RangeFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let data: Data
    private let queue = DispatchQueue(label: "PlaybackFixtureUpstream")
    var port: UInt16? { listener.port?.rawValue }

    init(data: Data) throws {
        self.data = data
        self.listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = buffered
            if let bytes { request.append(bytes) }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, buffered: request) }
                return
            }
            let range = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
            let values = range?.components(separatedBy: "bytes=").last?.split(separator: "-", omittingEmptySubsequences: false)
            let start = values?.first.flatMap { Int($0) } ?? 0
            let end = min(values?.last.flatMap { Int($0) } ?? (self.data.count - 1), self.data.count - 1)
            guard start >= 0, start <= end else { connection.cancel(); return }
            let body = self.data.subdata(in: start..<(end + 1))
            let status = range == nil ? "200 OK" : "206 Partial Content"
            var headers = "HTTP/1.1 \(status)\r\nContent-Type: video/mp4\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            if range != nil { headers += "Content-Range: bytes \(start)-\(end)/\(self.data.count)\r\n" }
            var response = Data((headers + "\r\n").utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
