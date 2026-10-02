//
//  FFmpegNetworkDemuxer.swift
//  Paladala
//
//  Network-capable FFmpeg demuxer for B站 CDN streaming.
//  Extends the base FFmpegDemuxer with HTTP/HTTPS support and
//  custom header injection (Referer, User-Agent) required by
//  Bilibili's CDN access control.
//
//  Phase 1: B站 CDN Integration
//  - HTTP/HTTPS streaming via FFmpeg's libavformat
//  - Custom header injection for B站 CDN authentication
//  - Integration with CDNManager for endpoint selection
//

import Foundation
import CoreMedia

/// Errors specific to network streaming operations.
enum FFmpegNetworkError: Error, Equatable {
    /// The URL scheme is not supported (only http/https allowed).
    case unsupportedScheme(String)
    /// Failed to set up HTTP headers for the request.
    case headerSetupFailed(String)
    /// Network timeout during streaming.
    case timeout
    /// CDN returned an error status.
    case cdnError(Int, String)
}

/// Network-capable demuxer that extends FFmpegDemuxer with B站 CDN support.
///
/// This class handles:
/// 1. HTTP/HTTPS URL opening with custom headers
/// 2. B站 CDN authentication (Referer, User-Agent)
/// 3. DASH segment streaming with CDN endpoint selection
actor FFmpegNetworkDemuxer {

    // MARK: - Types

    /// Represents a B站 CDN endpoint with latency information.
    struct CDNEndpoint: Sendable {
        let host: String
        let latencyMs: Int?
        let isReachable: Bool

        var baseURL: URL? {
            URL(string: "https://\(host)")
        }
    }

    /// Configuration for network streaming.
    struct NetworkConfig: Sendable {
        /// B站 Referer header (required for CDN access).
        let referer: String
        /// Custom User-Agent string.
        let userAgent: String
        /// Connection timeout in seconds.
        let timeout: TimeInterval
        /// Number of retry attempts for failed segments.
        let retryCount: Int
        /// Preferred CDN endpoints (ordered by preference).
        let cdnEndpoints: [CDNEndpoint]

        static let `default` = NetworkConfig(
            referer: "https://www.bilibili.com",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            timeout: 30.0,
            retryCount: 3,
            cdnEndpoints: []
        )
    }

    // MARK: - State

    private var demuxer: FFmpegDemuxer?
    private var config: NetworkConfig
    private var currentEndpoint: CDNEndpoint?
    private var retryAttempts: Int = 0

    // MARK: - Initialization

    init(config: NetworkConfig = .default) {
        self.config = config
        self.demuxer = nil
    }

    // MARK: - Public API

    /// Opens a network stream from a B站 CDN URL.
    ///
    /// This method:
    /// 1. Selects the best CDN endpoint based on latency
    /// 2. Constructs the full URL with proper headers
    /// 3. Opens the stream using FFmpeg with custom options
    ///
    /// - Parameters:
    ///   - playback: The BiliPlayback containing CDN URLs
    ///   - preferredHost: Optional preferred CDN host override
    /// - Throws: FFmpegDemuxerError or FFmpegNetworkError
    func openNetworkStream(
        playback: BiliPlayback,
        preferredHost: String? = nil
    ) async throws {
        // Determine the best CDN endpoint
        let endpoint = try await selectEndpoint(
            playback: playback,
            preferredHost: preferredHost
        )
        self.currentEndpoint = endpoint

        // Construct the streaming URL
        guard let streamURL = constructStreamURL(
            playback: playback,
            endpoint: endpoint
        ) else {
            throw FFmpegNetworkError.headerSetupFailed("Failed to construct stream URL")
        }

        // Set up FFmpeg with custom headers
        try await openWithHeaders(url: streamURL)
    }

    /// Reads the next packet from the network stream.
    /// Automatically handles retry logic for transient failures.
    func readPacket() async throws -> AVPacket {
        do {
            let packet = try await demuxer?.readPacket()
            guard let p = packet else {
                throw FFmpegDemuxerError.readFailed(code: -1)
            }
            retryAttempts = 0 // Reset retry counter on success
            return p
        } catch {
            // Handle retry logic
            if retryAttempts < config.retryCount {
                retryAttempts += 1
                let delay = Double(retryAttempts) * 0.5 // Exponential backoff
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await readPacket() // Retry
            }
            throw error
        }
    }

    /// Seeks to the specified time in the stream.
    func seek(toSeconds seconds: Double) async -> Bool {
        return await demuxer?.seek(toSeconds: seconds) ?? false
    }

    /// Closes the network stream and releases resources.
    func close() {
        demuxer?.close()
        demuxer = nil
        currentEndpoint = nil
        retryAttempts = 0
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

        // Otherwise, use CDNManager to select the best endpoint
        let cdnManager = CDNManager.shared

        // Get the list of available nodes
        let nodes = await cdnManager.nodes()

        // If we have cached results, use the best one
        if let bestHost = cdnManager.currentBestHost {
            return CDNEndpoint(
                host: bestHost,
                latencyMs: cdnManager.results.first { $0.node.host == bestHost }?.latencyMs,
                isReachable: true
            )
        }

        // Fallback to the first available node
        guard let firstNode = nodes.first else {
            throw FFmpegNetworkError.cdnError(0, "No CDN endpoints available")
        }

        return CDNEndpoint(
            host: firstNode.host,
            latencyMs: nil,
            isReachable: true
        )
    }

    private func constructStreamURL(
        playback: BiliPlayback,
        endpoint: CDNEndpoint
    ) -> URL? {
        // For DASH playback, we need to construct the segment URL
        guard let dash = playback.dash else {
            // Fallback to the fallback URL with CDN host replacement
            guard let fallbackURL = playback.fallbackURL,
                  var components = URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false),
                  let originalHost = fallbackURL.host else {
                return nil
            }

            // Replace the host with the CDN endpoint
            components.host = endpoint.host
            return components.url
        }

        // For DASH, construct the video segment URL
        let videoTrack = dash.video
        guard var components = URLComponents(url: videoTrack.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // Replace the host with the CDN endpoint
        components.host = endpoint.host

        return components.url
    }

    private func openWithHeaders(url: URL) async throws {
        // Create a new demuxer
        let newDemuxer = FFmpegDemuxer()

        // Set up custom headers for B站 CDN access
        // FFmpeg supports custom headers via the 'headers' option
        var headers = ""
        headers += "Referer: \(config.referer)\r\n"
        headers += "User-Agent: \(config.userAgent)\r\n"

        // For now, we use the file-based approach with FFmpeg
        // In a more advanced implementation, we'd use the FFmpeg network layer
        // directly with custom headers

        // Try to open the URL
        // Note: FFmpegDemuxer currently only supports local files
        // We need to either:
        // 1. Download segments and play locally (not ideal)
        // 2. Extend FFmpegDemuxer to support network URLs
        // 3. Use FFmpeg's built-in HTTP support with custom headers

        // For Phase 1, we'll use approach 3: extend the demuxer to support network URLs
        // This requires modifying FFmpegDemuxer to use avformat_open_input with custom options

        throw FFmpegNetworkError.headerSetupFailed("Network streaming not yet implemented - Phase 1 in progress")
    }
}

// MARK: - BiliPlayback Extension

extension BiliPlayback {
    /// Extracts the CDN host from the playback URL for endpoint selection.
    var cdnHost: String? {
        if let dash = dash {
            return dash.video.baseURL.host
        }
        return fallbackURL?.host
    }

    /// All available CDN hosts from backup URLs.
    var allCDNHosts: [String] {
        var hosts: [String] = []

        if let dash = dash {
            if let host = dash.video.baseURL.host {
                hosts.append(host)
            }
            hosts.append(contentsOf: dash.video.backupURLs.compactMap { $0.host })

            if let audio = dash.audio {
                if let host = audio.baseURL.host, !hosts.contains(host) {
                    hosts.append(host)
                }
                hosts.append(contentsOf: audio.backupURLs.compactMap { $0.host }.filter { !hosts.contains($0) })
            }
        }

        if let host = fallbackURL?.host, !hosts.contains(host) {
            hosts.append(host)
        }

        return hosts
    }
}
