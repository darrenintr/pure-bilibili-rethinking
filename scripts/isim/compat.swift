// iSim-only compatibility additions for the clean-room Linux simulator SDK.
// This source is appended to the main app during CI, not compiled on Apple platforms.
// Remove shims as kolabs-dev/isim implements the corresponding Foundation/AVFoundation APIs.

import Foundation
import AVFoundation

extension UserDefaults {
    func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }
}

extension Data {
    func range(of needle: Data) -> Range<Int>? {
        let haystack = [UInt8](self)
        let pattern = [UInt8](needle)
        if pattern.isEmpty { return 0..<0 }
        guard pattern.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - pattern.count) {
            var matches = true
            for offset in pattern.indices where haystack[start + offset] != pattern[offset] {
                matches = false
                break
            }
            if matches { return start..<(start + pattern.count) }
        }
        return nil
    }
}

extension FileManager {
    func url(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask,
        appropriateFor unusedURL: URL?,
        create: Bool
    ) throws -> URL {
        guard let result = urls(for: directory, in: domainMask).first else {
            throw NSError(domain: "dev.isim.compat", code: 2)
        }
        if create {
            try createDirectory(at: result, withIntermediateDirectories: true)
        }
        return result
    }
}

// iSim 0.24 does not expose AVPlayerItem's error-log API. The app uses
// it for supplementary diagnostics; playback error/status handling remains.
struct IsimAVPlayerItemErrorLogEvent {
    let errorStatusCode: Int = 0
    let errorDomain: String = ""
    let errorComment: String? = nil
    let uri: String? = nil
    let serverAddress: String? = nil
    let playbackSessionID: String? = nil
}
struct IsimAVPlayerItemErrorLog {
    let events: [IsimAVPlayerItemErrorLogEvent] = []
}
extension AVPlayerItem {
    func errorLog() -> IsimAVPlayerItemErrorLog? { nil }
}
