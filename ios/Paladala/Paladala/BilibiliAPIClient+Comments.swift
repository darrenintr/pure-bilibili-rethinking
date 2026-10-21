import Foundation

// Comment actions: replies page, post, like, hate, report.

extension BilibiliAPIClient {
    func repliesPage(aid: Int, rpid: Int, pn: Int = 1, pageSize: Int = 20) async throws -> CommentPage {
        // The sub-reply endpoint uses a plain `pn` page-number cursor,
        // not the `pagination_str` opaque cursor of the main reply
        // endpoint. We do not round-trip `next` through `CommentPage`
        // for this path because `ReplyListViewModel.loadMore` tracks
        // `pn` locally; leaving `next` nil here is intentional.
        let payload: APIResponse<CommentPayload> = try await get(
            baseURL: baseURL,
            path: "/x/v2/reply/reply",
            queryItems: [
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "oid", value: "\(aid)"),
                URLQueryItem(name: "root", value: "\(rpid)"),
                URLQueryItem(name: "pn", value: "\(pn)"),
                URLQueryItem(name: "ps", value: "\(pageSize)")
            ]
        )
        try payload.requireOK()
        let items = payload.value?.replies?.items.map(\.model) ?? []
        return CommentPage(
            items: items,
            next: nil,
            isEnd: payload.value?.cursor?.isEnd ?? true,
            totalCount: payload.value?.cursor?.allCount ?? 0
        )
    }

    func postComment(aid: Int, message: String, root: Int? = nil, parent: Int? = nil) async throws {
        var params: [String: String] = [
            "type": "1",
            "oid": "\(aid)",
            "message": message,
            "plat": "3" // iOS
        ]
        if let root { params["root"] = "\(root)" }
        if let parent { params["parent"] = "\(parent)" }

        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/reply/add",
            parameters: params
        )
        try payload.requireOK()
    }

    func likeComment(aid: Int, rpid: Int, action: Int) async throws {
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/reply/action",
            parameters: [
                "type": "1",
                "oid": "\(aid)",
                "rpid": "\(rpid)",
                "action": "\(action)"
            ]
        )
        try payload.requireOK()
    }

    func hateComment(aid: Int, rpid: Int, action: Int) async throws {
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/reply/hate",
            parameters: [
                "type": "1",
                "oid": "\(aid)",
                "rpid": "\(rpid)",
                "action": "\(action)"
            ]
        )
        try payload.requireOK()
    }

    func reportComment(aid: Int, rpid: Int, reason: Int, content: String? = nil) async throws {
        var params = [
            "type": "1",
            "oid": "\(aid)",
            "rpid": "\(rpid)",
            "reason": "\(reason)"
        ]
        if let content { params["content"] = content }
        let payload: APIResponse<EmptyPayload> = try await post(
            baseURL: baseURL,
            path: "/x/v2/reply/report",
            parameters: params
        )
        try payload.requireOK()
    }
}
