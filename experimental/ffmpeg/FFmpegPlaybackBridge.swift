//
//  FFmpegPlaybackBridge.swift
//  Paladala
//
//  Bridge between BiliPlayback (B站 API model) and FFmpegPlaybackEngine.
//  Converts B站 DASH/HLS playback metadata into FFmpeg-compatible streaming
//  sessions with CDN endpoint selection and authentication.
//
//  Phase 1: B站 CDN Integration
//

import Foundation
import CoreMedia

/// Bridge that converts BiliPlayback into FFmpeg playback sessions.
///
/// Responsibilities:
/// 1. Extract CDN URLs from BiliPlayback (DASH or fallback MP4)
/// 2. Select optimal CDN endpoint using CDNManager
/// 3. Configure FFmpeg with proper headers (Referer, User-Agent)
/// 4. Manage the FFmpegPlaybackEngine lifecycle
@MainActor
final class FFmpegPlaybackBridge {

    // MARK: - Types

    /// Represents a prepared playback session.
    struct Session {
        /// The underlying FFmpeg playback engine.
        let engine: FFmpegPlaybackEngine
        /// Selected CDN endpoint for diagnostics.
        let endpoint: CDNEndpoint
        /// Original playback metadata.
        let playback: BiliPlayback
        /// Video information.
        let video: BiliVideo
    }

    /// Errors that can occur during bridge operations.
    enum BridgeError: Error, LocalizedError {
        case noPlayableSource
        case cdnSelectionFailed(String)
        case engineCreationFailed(String)
        case invalidURL(String)
        case streamingNotSupported(String)

        var errorDescription: String? {
            switch self {
            case .noPlayableSource:
                return "无法找到可播放的视频源"
            case .cdnSelectionFailed(let reason):
                return "CDN 选择失败: \(reason)"
            case .engineCreationFailed(let reason):
                return "播放引擎创建失败: \(reason)"
            case .invalidURL(let url):
                return "无效的 URL: \(url)"
            case .streamingNotSupported(let reason):
                return "流媒体不支持: \(reason)"
            }
        }
    }

    // MARK: - Properties

    private let cdnManager: CDNManager
    private var activeSession: Session?

    // MARK: - Initialization

    init(cdnManager: CDNManager = .shared) {
        self.cdnManager = cdnManager
    }

    // MARK: - Public API

    /// Prepares a playback session from BiliPlayback metadata.
    ///
    /// This is the main entry point for starting FFmpeg-based playback
    /// of B站 content. It handles CDN selection, URL construction, and
    /// engine initialization.
    ///
    /// - Parameters:
    ///   - playback: The BiliPlayback metadata from B站 API
    ///   - video: The BiliVideo metadata for display
    ///   - preferredHost: Optional preferred CDN host override
    /// - Returns: A prepared Session ready for playback
    func prepareSession(
        playback: BiliPlayback,
        video: BiliVideo,
        preferredHost: String? = nil
    ) async throws -> Session {
        // Clean up any existing session
        await teardownSession()

        // Validate that we have a playable source
        guard playback.dash != nil || playback.fallbackURL != nil else {
            throw BridgeError.noPlayableSource
        }

        // Select CDN endpoint
        let endpoint = try await selectEndpoint(
            playback: playback,
            preferredHost: preferredHost
        )

        // Create the FFmpeg playback engine with network configuration
        let engine = try await createEngine(
            playback: playback,
            endpoint: endpoint
        )

        // Create and store the session
        let session = Session(
            engine: engine,
            endpoint: endpoint,
            playback: playback,
            video: video
        )
        self.activeSession = session

        return session
    }

    /// Tears down the active session and releases resources.
    func teardownSession() async {
        if let session = activeSession {
            await session.engine.unload()
            activeSession = nil
        }
    }

    /// Returns the currently active session, if any.
    var currentSession: Session? {
        activeSession
    }

    // MARK: - Private Methods

    private func selectEndpoint(
        playback: BiliPlayback,
        preferredHost: String?
    ) async throws -> CDNEndpoint {
        // If a specific host is requested, use it
        if let host = preferredHost {
            return CDNEndpoint(host: host, latencyMs: nil, isReachable: true)
        }

        // Use CDNManager to get the best endpoint
        let cdnManager = CDNManager.shared

        // Get available hosts from playback
        let availableHosts = playback.allCDNHosts

        // If we have cached results, use the best one
        if let bestHost = cdnManager.currentBestHost,
           availableHosts.contains(bestHost) {
            return CDNEndpoint(
                host: bestHost,
                latencyMs: cdnManager.results.first { $0.node.host == bestHost }?.latencyMs,
                isReachable: true
            )
        }

        // Get the default host from playback
        if let defaultHost = playback.cdnHost {
            return CDNEndpoint(host: defaultHost, latencyMs: nil, isReachable: true)
        }

        // Fallback to CDNManager's default
        let defaultHost = CDNManager.defaultHost
        return CDNEndpoint(host: defaultHost, latencyMs: nil, isReachable: true)
    }

    private func createEngine(
        playback: BiliPlayback,
        endpoint: CDNEndpoint
    ) async throws -> FFmpegPlaybackEngine {
        // Create the playback engine
        let engine = FFmpegPlaybackEngine()

        // Configure the engine with network-capable frame callback
        // Note: This is a simplified version - actual implementation
        // would need proper frame handling and display integration

        // For Phase 1, we'll use a placeholder implementation
        // that loads the stream URL with custom headers

        return engine
    }

    /// Constructs the streaming URL with the selected CDN endpoint.
    private func constructStreamURL(
        playback: BiliPlayback,
        endpoint: CDNEndpoint
    ) -> URL? {
        // Implementation would construct the appropriate URL
        // based on DASH or fallback format
        playback.dash?.video.baseURL ?? playback.fallbackURL
    }
}

// MARK: - CDNManager Extension

extension CDNManager {
    /// Returns the default CDN host used when no better option is available.
    static var defaultHost: String {
        "upos-sz-mirrorali.bilivideo.com"
    }
}
