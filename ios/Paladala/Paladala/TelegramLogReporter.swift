//
//  TelegramLogReporter.swift
//  Paladala
//
//  Uploads diagnostic log files to a Telegram channel via the
//  Bot API `sendDocument` endpoint.
//
//  Caller flow (`LogViewerView`):
//    1. `DiagnosticLogger.shared.export(activeAccount:)` —
//       produces a temp `.txt` URL with the full deep report.
//    2. `TelegramLogReporter.shared.upload(fileURL:caption:)` —
//       builds a multipart body, POSTs via URLSession.upload,
//       decodes the Telegram response, returns the message id.
//
//  Implemented as an `actor` so concurrent button taps
//  serialise — we don't want two uploads racing the progress
//  state on the calling view, and we don't want to interleave
//  their `URLRequest` builds on the main actor.
//
//  The multipart body is hand-rolled (no third-party HTTP
//  library).  Boundary is a UUID prefixed with a tag for
//  easy identification in network traces.  Body shape:
//
//    --BOUNDARY\r\n
//    Content-Disposition: form-data; name="chat_id"\r\n\r\n
//    <value>\r\n
//    --BOUNDARY\r\n
//    Content-Disposition: form-data; name="caption"\r\n\r\n
//    <value>\r\n
//    --BOUNDARY\r\n
//    Content-Disposition: form-data; name="document"; filename="X"\r\n
//    Content-Type: text/plain\r\n\r\n
//    <bytes>
//    \r\n
//    --BOUNDARY--\r\n
//
//  Telegram response shape (only fields we care about):
//    { "ok": true,  "result": { "message_id": 123, "date": 172... } }
//    { "ok": false, "description": "Bad Request: chat not found" }
//

import Foundation

actor TelegramLogReporter {
    static let shared = TelegramLogReporter()

    /// Localised failures surfaced to the toast in the calling
    /// view.  Each case maps to a user-readable string in
    /// `errorDescription` (Chinese to match the rest of the
    /// app's UX).
    enum ReporterError: LocalizedError {
        /// File at the supplied URL does not exist (e.g. user
        /// cleared the temp dir between export and upload).
        case missingFile
        /// HTTP-level failure.  Carries the status code.
        case http(Int)
        /// The response wasn't a valid HTTPURLResponse at all.
        case malformedResponse
        /// Telegram returned `ok: false`.  Carries the upstream
        /// `description` for triage.
        case telegramError(String)
        /// Body assembly or response decoding threw.
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingFile:
                return "日誌檔案不存在"
            case .http(let code):
                return "上傳失敗：HTTP \(code)"
            case .malformedResponse:
                return "上傳失敗：響應格式異常"
            case .telegramError(let msg):
                return "Telegram 拒絕：\(msg)"
            case .decoding(let msg):
                return "響應解析失敗：\(msg)"
            }
        }
    }

    /// Successful upload metadata — useful for the toast and
    /// for future "last upload" surfacing.
    struct Result: Sendable {
        let messageID: Int64
        let date: Date
    }

    /// Uploads the file at `fileURL` to the configured channel
    /// with `caption` rendered under the document.  Returns
    /// the assigned message id and the server's `date` (epoch
    /// seconds, converted to `Date`).
    ///
    /// Throws `ReporterError` on any failure; the caller is
    /// expected to surface `error.localizedDescription` to the
    /// user.
    func upload(fileURL: URL, caption: String?) async throws -> Result {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ReporterError.missingFile
        }

        let boundary = "----PaladalaBoundary\(UUID().uuidString)"
        let url = TelegramLogConfig.apiBase.appendingPathComponent(
            "bot\(TelegramLogConfig.botToken)/sendDocument"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            TelegramLogConfig.userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = TelegramLogConfig.requestTimeout

        let body = try buildMultipartBody(
            boundary: boundary,
            fields: [
                "chat_id": TelegramLogConfig.chatID,
                "caption": caption ?? ""
            ],
            fileFieldName: "document",
            fileURL: fileURL
        )

        // `.upload(for:from:)` is the iOS 13+ async API — it
        // wraps the data into a temp file URL internally so we
        // never have to manage FileHandle ourselves.  Returns
        // `(Data, URLResponse)`; we throw on the response, not
        // the data, so the data round-trips even on small
        // payloads.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(
                for: request, from: body
            )
        } catch {
            // URL-level errors (no network, timeout, etc.) get
            // surfaced verbatim — `localizedDescription` is
            // already user-friendly (e.g. "The Internet
            // connection appears to be offline.").
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw ReporterError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ReporterError.http(http.statusCode)
        }

        // Telegram wraps every method response in
        //   { "ok": Bool, "description": String?, "result": ... }
        // `result` is method-specific; for `sendDocument` it's
        // a Message object.  We only pull out the two fields
        // the toast cares about.
        struct TGEnvelope: Decodable {
            let ok: Bool
            let description: String?
            let result: TGMessage?
        }
        struct TGMessage: Decodable {
            let message_id: Int64
            let date: Int
        }
        let envelope: TGEnvelope
        do {
            envelope = try JSONDecoder().decode(TGEnvelope.self, from: data)
        } catch {
            throw ReporterError.decoding(error.localizedDescription)
        }
        guard envelope.ok, let r = envelope.result else {
            throw ReporterError.telegramError(
                envelope.description ?? "unknown"
            )
        }
        return Result(
            messageID: r.message_id,
            date: Date(timeIntervalSince1970: TimeInterval(r.date))
        )
    }

    // MARK: - multipart body

    /// Build a single in-memory `multipart/form-data` body.
    /// The text fields are written first so the file part lands
    /// at the end — matches what most curl-style clients do
    /// and makes the body easier to eyeball in a packet dump.
    private func buildMultipartBody(
        boundary: String,
        fields: [String: String],
        fileFieldName: String,
        fileURL: URL
    ) throws -> Data {
        let crlf = "\r\n"
        var data = Data()

        // Text fields.  Skip empty values so we don't send
        // empty `caption=` lines — Telegram's parser is
        // permissive but cleaner input is easier to debug.
        for (name, value) in fields where !value.isEmpty {
            data.append(string("--\(boundary)\(crlf)"))
            data.append(string(
                "Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)"
            ))
            data.append(string("\(value)\(crlf)"))
        }

        // File part.  Filename is the temp file's
        // `lastPathComponent` (matches the on-disk name in
        // `DiagnosticLogger.export`, e.g.
        // `Paladala_Diagnostic_172...234.txt`).  Content-Type
        // is fixed to `text/plain` because the export is
        // always a UTF-8 .txt regardless of file extension.
        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        data.append(string("--\(boundary)\(crlf)"))
        data.append(string(
            "Content-Disposition: form-data; name=\"\(fileFieldName)\";"
            + " filename=\"\(filename)\"\(crlf)"
        ))
        data.append(string("Content-Type: text/plain\(crlf)\(crlf)"))
        data.append(fileData)
        data.append(string(crlf))

        // Closing boundary.  The trailing CRLF is required by
        // RFC 7578 — Telegram's parser is strict about it.
        data.append(string("--\(boundary)--\(crlf)"))
        return data
    }

    /// Small helper — `Data(string.utf8)` is verbose enough
    /// that it warrants a one-liner.  Force-unwrap is safe
    /// because UTF-8 never fails on `String`.
    private func string(_ s: String) -> Data {
        Data(s.utf8)
    }
}
