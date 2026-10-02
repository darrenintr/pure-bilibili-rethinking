import Foundation

@MainActor
final class SponsorBlockService {
    static let shared = SponsorBlockService()

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let headers: [String: String] = [
        "origin": "Paladala-iOS",
        "x-ext-version": "1.0.0"
    ]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    private var baseURL: String {
        SponsorBlockManager.shared.config.serverURL
    }

    private func request(path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        return req
    }

    private func validateResponse(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw SponsorError.networkError }
        if http.statusCode == 404 { return Data() }
        guard http.statusCode == 200 else {
            if let body = String(data: data, encoding: .utf8) {
                throw SponsorError.httpError(http.statusCode, body)
            }
            throw SponsorError.httpError(http.statusCode, nil)
        }
        return data
    }

    // MARK: - Fetch

    func fetchSegments(videoID: String, categories: [SponsorCategory]) async throws -> [SponsorSegment] {
        var components = URLComponents(string: "\(baseURL)/skipSegments")
        var queryItems = [URLQueryItem(name: "videoID", value: videoID)]
        if !categories.isEmpty {
            let cats = categories.map(\.rawValue)
            if let data = try? JSONSerialization.data(withJSONObject: cats),
               let str = String(data: data, encoding: .utf8) {
                queryItems.append(URLQueryItem(name: "categories", value: str))
            }
        }
        components?.queryItems = queryItems

        guard let url = components?.url else { throw SponsorError.invalidURL }

        var req = URLRequest(url: url)
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        req.setValue("1", forHTTPHeaderField: "x-skip-cache")

        let (data, response) = try await session.data(for: req)
        let validated = try validateResponse(data, response)
        guard !validated.isEmpty else { return [] }
        return try decoder.decode([SponsorSegment].self, from: validated)
    }

    // MARK: - Submit

    func submitSegment(videoID: String, cid: String?, category: String, startTime: Double, endTime: Double, userID: String, videoDuration: Double) async throws {
        var req = request(path: "/skipSegments")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "videoID": videoID, "userID": userID, "videoDuration": videoDuration,
            "segments": [["segment": [startTime, endTime], "category": category, "actionType": "skip"]]
        ]
        if let cid { body["cid"] = cid }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        _ = try validateResponse(data, response)
    }

    // MARK: - Vote

    func vote(uuid: String, userID: String, type: Int) async throws {
        var req = request(path: "/voteOnSponsorTime")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["UUID": uuid, "userID": userID, "type": type])
        let (data, response) = try await session.data(for: req)
        _ = try validateResponse(data, response)
    }

    // MARK: - Record View

    func recordView(uuid: String) async throws {
        var req = request(path: "/viewedVideoSponsorTime")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["UUID": uuid])
        let (data, response) = try await session.data(for: req)
        _ = try validateResponse(data, response)
    }
}

enum SponsorError: LocalizedError, Sendable {
    case invalidURL
    case networkError
    case httpError(Int, String?)
    case decodeError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "無效的 URL"
        case .networkError: return "網路連線失敗"
        case .httpError(let code, let body):
            if let body, !body.isEmpty { return "伺服器錯誤 (\(code)): \(body)" }
            return "伺服器錯誤 (HTTP \(code))"
        case .decodeError: return "資料解析失敗"
        }
    }
}
