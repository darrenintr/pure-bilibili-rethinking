//
//  FFmpegStreamingEngine.swift
//  Paladala
//
//  Unified streaming engine that integrates FFmpegPlaybackEngine with
//  B站 CDN streaming capabilities. This is the main entry point for
//  Phase 1 B站 CDN integration.
//

import Foundation
import CoreMedia

/// Unified streaming engine for B站 CDN content.
///
/// This engine combines:
/// - FFmpegPlaybackEngine for decoding and playback
/// - DASHSegmentFetcher for segment fetching
/// - CDNManager for endpoint selection
///
/// Usage:
/// ```
/// let engine = FFmpegStreamingEngine()
/// try await engine.loadPlayback(biliPlayback, video: video)
/// engine.play()
/// ```
@MainActor
final class FFmpegStreamingEngine: ObservableObject {

    // MARK: - Types

    /// Engine playback state.
    enum State: Equatable, Sendable {
        case idle
        case loading
        case buffering
        case playing
        case paused
        case seeking
        case failed(StreamingError)
        case ended
    }

    /// Streaming errors.
    enum StreamingError: Error, LocalizedError, Sendable {
        case noPlayableSource
        case cdnUnavailable
        case segmentFetchFailed(String)
        case engineCreationFailed(String)
        case playbackFailed(String)
        case networkTimeout

        var errorDescription: String? {
            switch self {
            case .noPlayableSource:
                return "无法找到可播放的视频源"
            case .cdnUnavailable:
                return "CDN 暂不可用，请稍后重试"
            case .segmentFetchFailed(let reason):
                return "片段加载失败: \(reason)"
            case .engineCreationFailed(let reason):
                return "播放引擎创建失败: \(reason)"
            case .playbackFailed(let reason):
                return "播放失败: \(reason)"
            case .networkTimeout:
                return "网络连接超时，请检查网络"
            }
        }
    }

    /// Playback progress information.
    struct Progress: Sendable {
        let currentTime: Double
        let duration: Double
        let bufferedTime: Double
        let isSeekable: Bool
    }

    // MARK: - Published State

    @Published private(set) var state: State = .idle
    @Published private(set) var progress: Progress = .init(
        currentTime: 0,
        duration: 0,
        bufferedTime: 0,
        isSeekable: false
    )

    // MARK: - Private Properties

    private var engine: FFmpegPlaybackEngine?
    private var segmentFetcher: DASHSegmentFetcher?
    private var bridge: FFmpegPlaybackBridge?

    private var playbackTask: Task<Void, Never>?
    private var progressUpdateTask: Task<Void, Never>?

    private var currentPlayback: BiliPlayback?
    private var currentVideo: BiliVideo?

    // MARK: - Initialization

    init() {
        // Initialize components on first use
    }

    deinit {
        progressUpdateTask?.cancel()
        playbackTask?.cancel()
    }

    // MARK: - Public API

    /// Loads a B站 playback for streaming.
    ///
    /// - Parameters:
    ///   - playback: The BiliPlayback from B站 API
    ///   - video: Video metadata for display
    ///   - preferredHost: Optional preferred CDN host
    func loadPlayback(
        _ playback: BiliPlayback,
        video: BiliVideo,
        preferredHost: String? = nil
    ) async {
        // Cancel any existing playback
        await stop()

        state = .loading
        currentPlayback = playback
        currentVideo = video

        do {
            // Initialize bridge and fetcher
            bridge = FFmpegPlaybackBridge()
            segmentFetcher = DASHSegmentFetcher()

            // Prepare the session
            guard let bridge = bridge else {
                throw StreamingError.engineCreationFailed("Bridge initialization failed")
            }

            let session = try await bridge.prepareSession(
                playback: playback,
                video: video,
                preferredHost: preferredHost
            )

            // Store the engine
            engine = session.engine

            // Start progress updates
            startProgressUpdates()

            // Update state
            state = .paused

            // Update duration in progress
            if let duration = session.engine.durationSeconds {
                progress = Progress(
                    currentTime: 0,
                    duration: duration,
                    bufferedTime: 0,
                    isSeekable: true
                )
            }

        } catch {
            state = .failed(.playbackFailed(error.localizedDescription))
        }
    }

    /// Starts or resumes playback.
    func play() {
        guard let engine = engine else { return }

        engine.play()
        state = .playing
    }

    /// Pauses playback.
    func pause() {
        guard let engine = engine else { return }

        engine.pause()
        state = .paused
    }

    /// Seeks to the specified time.
    ///
    /// - Parameter time: Target time in seconds
    func seek(to time: Double) {
        guard let engine = engine else { return }

        let wasPlaying = state == .playing
        state = .seeking

        engine.seek(toSeconds: time)

        // Resume previous state
        state = wasPlaying ? .playing : .paused
    }

    /// Stops playback and releases resources.
    func stop() async {
        progressUpdateTask?.cancel()
        playbackTask?.cancel()

        if let engine = engine {
            await engine.unload()
        }

        // Clean up bridge and fetcher
        if let bridge = bridge {
            await bridge.teardownSession()
        }

        engine = nil
        bridge = nil
        segmentFetcher = nil
        currentPlayback = nil
        currentVideo = nil

        state = .idle
        progress = Progress(
            currentTime: 0,
            duration: 0,
            bufferedTime: 0,
            isSeekable: false
        )
    }

    // MARK: - Private Methods

    private func startProgressUpdates() {
        progressUpdateTask?.cancel()

        progressUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self,
                      let engine = self.engine else {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    continue
                }

                // Update progress
                let currentTime = engine.currentTime
                let duration = engine.durationSeconds ?? 0

                // Estimate buffered time (simplified)
                let bufferedTime = min(currentTime + 10, duration)

                await MainActor.run {
                    self.progress = Progress(
                        currentTime: currentTime,
                        duration: duration,
                        bufferedTime: bufferedTime,
                        isSeekable: duration > 0
                    )
                }

                // Check for end of playback
                if currentTime >= duration - 0.5 && duration > 0 {
                    await MainActor.run {
                        self.state = .ended
                    }
                }

                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }
    }
}

// MARK: - FFmpegPlaybackEngine Extension

extension FFmpegPlaybackEngine {
    /// Current playback position in seconds.
    var currentTime: Double {
        // This would need to be implemented in FFmpegPlaybackEngine
        // For now, returning 0 as placeholder
        0
    }

    /// Total duration in seconds (nil for live streams).
    var durationSeconds: Double? {
        // This would need to be implemented in FFmpegPlaybackEngine
        // For now, returning nil as placeholder
        nil
    }
}
