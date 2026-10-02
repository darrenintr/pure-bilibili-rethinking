//
//  DASHSegmentFetcher.swift
//  Paladala
//
//  DASH segment fetching and management for FFmpeg streaming.
//  Handles segment downloading, caching, and playback coordination.
//
//  Phase 1: B站 CDN Integration
//

import Foundation

/// Represents a DASH segment (initialization or media segment).
struct DASHSegment: Sendable {
    /// Segment URL (may be relative or absolute).
    let url: URL
    /// Byte range for this segment (nil for full file).
    let byteRange: ClosedRange<Int>?
    /// Segment duration in seconds.
    let duration: Double
    /// Whether this is an initialization segment.
    let isInitSegment: Bool
    /// Segment sequence number for ordering.
    let sequenceNumber: Int
}

/// Manages DASH segment fetching and caching.
actor DASHSegmentFetcher {

    // MARK: - Types

    /// Configuration for segment fetching.
    struct Configuration: Sendable {
        /// Number of segments to prefetch ahead of current position.
        let prefetchCount: Int
        /// Maximum cache size in bytes.
        let maxCacheSize: Int
        /// Request timeout in seconds.
        let timeout: TimeInterval
        /// Number of retry attempts for failed segments.
        let retryCount: Int
        /// CDN endpoint selection strategy.
        let cdnSelection: CDNSelectionStrategy

        enum CDNSelectionStrategy: Sendable {
            /// Use the lowest latency endpoint.
            case lowestLatency
            /// Use the first available endpoint.
            case firstAvailable
            /// Round-robin through endpoints.
            case roundRobin
        }

        static let `default` = Configuration(
            prefetchCount: 3,
            maxCacheSize: 100 * 1024 * 1024, // 100 MB
            timeout: 30.0,
            retryCount: 3,
            cdnSelection: .lowestLatency
        )
    }

    /// Cache entry for a fetched segment.
    private struct CacheEntry {
        let data: Data
        let timestamp: Date
        let segment: DASHSegment
    }

    // MARK: - Properties

    private let config: Configuration
    private let session: URLSession
    private var cache: [URL: CacheEntry] = [:]
    private var currentCacheSize: Int = 0
    private var currentCDNIndex: Int = 0
    private var retryAttempts: [URL: Int] = [:]

    // MARK: - Initialization

    init(config: Configuration = .default) {
        self.config = config

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout * 2
        sessionConfig.httpAdditionalHeaders = [
            "Referer": "https://www.bilibili.com",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"
        ]

        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: - Public API

    /// Fetches a segment from the specified CDN endpoints.
    ///
    /// - Parameters:
    ///   - segment: The segment to fetch
    ///   - cdnEndpoints: List of available CDN endpoints (ordered by preference)
    /// - Returns: The segment data
    func fetchSegment(
        segment: DASHSegment,
        cdnEndpoints: [String]
    ) async throws -> Data {
        // Check cache first
        if let cached = await getCachedSegment(url: segment.url) {
            return cached
        }

        // Try each CDN endpoint
        let endpoints = selectEndpoints(from: cdnEndpoints)
        var lastError: Error?

        for endpoint in endpoints {
            do {
                let data = try await fetchSegmentFromCDN(
                    segment: segment,
                    cdnHost: endpoint
                )

                // Cache the successful result
                await cacheSegment(segment: segment, data: data)

                return data
            } catch {
                lastError = error
                continue // Try next endpoint
            }
        }

        // All endpoints failed
        throw lastError ?? FFmpegNetworkError.cdnError(0, "All CDN endpoints failed")
    }

    /// Prefetches segments ahead of current position.
    ///
    /// - Parameters:
    ///   - segments: All available segments
    ///   - currentIndex: Current playback position index
    ///   - cdnEndpoints: Available CDN endpoints
    func prefetchSegments(
        segments: [DASHSegment],
        currentIndex: Int,
        cdnEndpoints: [String]
    ) async {
        let prefetchEnd = min(currentIndex + config.prefetchCount, segments.count)

        for i in (currentIndex + 1)..<prefetchEnd {
            let segment = segments[i]

            // Skip if already cached
            guard await getCachedSegment(url: segment.url) == nil else { continue }

            // Fetch and cache (ignore errors for prefetch)
            _ = try? await fetchSegment(
                segment: segment,
                cdnEndpoints: cdnEndpoints
            )
        }
    }

    /// Clears the segment cache.
    func clearCache() {
        cache.removeAll()
        currentCacheSize = 0
        retryAttempts.removeAll()
    }

    // MARK: - Private Methods

    private func selectEndpoints(from cdnEndpoints: [String]) -> [String] {
        switch config.cdnSelection {
        case .lowestLatency, .firstAvailable:
            // Return in provided order (assumed pre-sorted by latency)
            return cdnEndpoints

        case .roundRobin:
            // Rotate through endpoints
            guard !cdnEndpoints.isEmpty else { return cdnEndpoints }
            let offset = currentCDNIndex % cdnEndpoints.count
            currentCDNIndex += 1
            return Array(cdnEndpoints[offset...] + cdnEndpoints[..<offset])
        }
    }

    private func fetchSegmentFromCDN(
        segment: DASHSegment,
        cdnHost: String
    ) async throws -> Data {
        // Construct the CDN URL
        var components = URLComponents(url: segment.url, resolvingAgainstBaseURL: false)
        components?.host = cdnHost

        guard let url = components?.url else {
            throw FFmpegNetworkError.invalidURL(segment.url.absoluteString)
        }

        // Build the request
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = config.timeout

        // Add byte range if specified
        if let byteRange = segment.byteRange {
            request.setValue("bytes=\(byteRange.lowerBound)-\(byteRange.upperBound)", forHTTPHeaderField: "Range")
        }

        // Perform the request with retry logic
        let retryCount = retryAttempts[url] ?? 0

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw FFmpegNetworkError.cdnError(0, "Invalid response")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw FFmpegNetworkError.cdnError(httpResponse.statusCode, "HTTP error")
            }

            // Clear retry count on success
            retryAttempts.removeValue(forKey: url)

            return data

        } catch {
            // Track retry attempts
            if retryCount < config.retryCount {
                retryAttempts[url] = retryCount + 1
            }
            throw error
        }
    }

    private func getCachedSegment(url: URL) async -> Data? {
        guard let entry = cache[url] else { return nil }

        // Check if cache entry is still valid (TTL of 5 minutes)
        let age = Date().timeIntervalSince(entry.timestamp)
        guard age < 300 else {
            // Remove expired entry
            cache.removeValue(forKey: url)
            currentCacheSize -= entry.data.count
            return nil
        }

        return entry.data
    }

    private func cacheSegment(segment: DASHSegment, data: Data) async {
        // Check if we have room in the cache
        while currentCacheSize + data.count > config.maxCacheSize && !cache.isEmpty {
            // Remove oldest entry
            if let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp }) {
                cache.removeValue(forKey: oldest.key)
                currentCacheSize -= oldest.value.data.count
            }
        }

        // Add to cache
        let entry = CacheEntry(
            data: data,
            timestamp: Date(),
            segment: segment
        )
        cache[segment.url] = entry
        currentCacheSize += data.count
    }
}
