import Foundation

// Danmaku: WBI-signed six-minute protobuf segments.

extension BilibiliAPIClient {
    /// Fetch the video's current player danmaku in six-minute protobuf
    /// segments. This matches the segmented WBI route used by the live web
    /// player, replacing the older XML list route.
    func danmaku(cid: Int, aid: Int = 0, duration: Int = 0) async throws -> [BiliDanmakuItem] {
        guard cid > 0 else { return [] }
        let segmentCount = duration > 0 ? ((duration - 1) / 360) + 1 : 1
        var items: [BiliDanmakuItem] = []

        for segmentIndex in 1...segmentCount {
            var queryItems = [
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "oid", value: "\(cid)"),
                URLQueryItem(name: "segment_index", value: "\(segmentIndex)"),
                URLQueryItem(name: "web_location", value: "1315875")
            ]
            if aid > 0 {
                queryItems.append(URLQueryItem(name: "pid", value: "\(aid)"))
            }

            do {
                let data = try await rawGet(
                    baseURL: baseURL,
                    path: "/x/v2/dm/wbi/web/seg.so",
                    queryItems: queryItems,
                    signWithWBI: true
                )
                items.append(contentsOf: try BiliDanmakuProtobufDecoder.parse(data))
            } catch {
                // Preserve the already-loaded prefix if a later segment is
                // unavailable (for example, a transient rate limit). The
                // first segment is required because it contains the start
                // of playback, so its failure remains visible to the caller.
                guard segmentIndex > 1, !items.isEmpty else { throw error }
                bpLog("Danmaku segment \(segmentIndex) failed; keeping \(items.count) earlier entries")
                break
            }
        }
        return items.sorted { $0.time < $1.time }
    }
}

// MARK: - Danmaku protobuf decoder

/// Minimal wire-format reader for `DmSegMobileReply` and its
/// `DanmakuElem` children. Keeping this local avoids adding a large
/// generated protobuf runtime for the handful of fields the overlay uses.
private enum BiliDanmakuProtobufDecoder {
    private enum DecodeError: Error {
        case malformed
    }

    static func parse(_ data: Data) throws -> [BiliDanmakuItem] {
        var reader = Reader(bytes: Array(data))
        var items: [BiliDanmakuItem] = []
        while !reader.isAtEnd {
            let key = try reader.readVarint()
            let field = Int(key >> 3)
            let wireType = Int(key & 0x7)
            guard field > 0 else { throw DecodeError.malformed }

            if field == 1, wireType == 2 {
                let bytes = try reader.readLengthDelimited()
                if let item = try parseElement(bytes, ordinal: items.count) {
                    items.append(item)
                }
            } else {
                try reader.skip(wireType: wireType)
            }
        }
        return items.sorted { $0.time < $1.time }
    }

    private static func parseElement(_ bytes: [UInt8], ordinal: Int) throws -> BiliDanmakuItem? {
        var reader = Reader(bytes: bytes)
        var id: UInt64 = 0
        var progress: UInt64 = 0
        var mode = 0
        var fontSize = 0
        var color: UInt64 = 0
        var text = ""

        while !reader.isAtEnd {
            let key = try reader.readVarint()
            let field = Int(key >> 3)
            let wireType = Int(key & 0x7)
            guard field > 0 else { throw DecodeError.malformed }

            switch (field, wireType) {
            case (1, 0): id = try reader.readVarint()
            case (2, 0): progress = try reader.readVarint()
            case (3, 0): mode = Int(truncatingIfNeeded: try reader.readVarint())
            case (4, 0): fontSize = Int(truncatingIfNeeded: try reader.readVarint())
            case (5, 0): color = try reader.readVarint()
            case (7, 2):
                let content = try reader.readLengthDelimited()
                if let decoded = String(bytes: content, encoding: .utf8) {
                    text = decoded
                }
            default:
                try reader.skip(wireType: wireType)
            }
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let parsedID = Int(truncatingIfNeeded: id)
        return BiliDanmakuItem(
            id: parsedID > 0 ? parsedID : ordinal,
            time: Double(progress) / 1_000,
            mode: mode,
            fontSize: fontSize,
            color: Int(truncatingIfNeeded: color),
            text: text
        )
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        mutating func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw DecodeError.malformed }
                let byte = bytes[offset]
                offset += 1
                let payload = UInt64(byte & 0x7f)
                if index == 9, payload > 1 { throw DecodeError.malformed }
                value |= payload << UInt64(index * 7)
                if byte & 0x80 == 0 { return value }
            }
            throw DecodeError.malformed
        }

        mutating func readLengthDelimited() throws -> [UInt8] {
            let length = try readVarint()
            guard length <= UInt64(bytes.count - offset) else {
                throw DecodeError.malformed
            }
            let end = offset + Int(length)
            let result = Array(bytes[offset..<end])
            offset = end
            return result
        }

        mutating func skip(wireType: Int) throws {
            switch wireType {
            case 0:
                _ = try readVarint()
            case 1:
                try skipBytes(8)
            case 2:
                let length = try readVarint()
                guard length <= UInt64(bytes.count - offset) else {
                    throw DecodeError.malformed
                }
                offset += Int(length)
            case 5:
                try skipBytes(4)
            default:
                throw DecodeError.malformed
            }
        }

        mutating func skipBytes(_ count: Int) throws {
            guard count <= bytes.count - offset else { throw DecodeError.malformed }
            offset += count
        }
    }
}
