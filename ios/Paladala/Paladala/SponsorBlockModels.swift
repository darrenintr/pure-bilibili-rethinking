import Foundation

enum SponsorCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case sponsor = "sponsor"
    case intro = "intro"
    case outro = "outro"
    case interaction = "interaction"
    case selfpromo = "selfpromo"
    case musicOfftopic = "music_offtopic"
    case preview = "preview"
    case filler = "filler"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sponsor: return "贊助廣告"
        case .intro: return "開場動畫"
        case .outro: return "結尾動畫"
        case .interaction: return "一鍵三連"
        case .selfpromo: return "自賣自誇"
        case .musicOfftopic: return "音樂無關"
        case .preview: return "預告/下集"
        case .filler: return "湊數填充"
        }
    }
}

enum SponsorActionType: String, Codable, Sendable {
    case skip = "skip"
    case mute = "mute"
    case full = "full"
    case poi = "poi"
    case chapter = "chapter"
}

struct SponsorSegment: Codable, Identifiable, Sendable {
    let uuid: String
    let videoID: String
    let cid: String?
    let segment: [Double]
    let category: String
    let actionType: String?
    let locked: Int?
    let votes: Int?
    let views: Int?
    let userID: String?
    let description: String?

    var id: String { uuid }

    var startTime: Double { segment.first ?? 0 }
    var endTime: Double { segment.last ?? 0 }

    var duration: Double { endTime - startTime }
}

struct SponsorSkipSegmentsResponse: Codable, Sendable {
    let segments: [SponsorSegment]
}

struct SponsorConfig: Codable, Equatable, Sendable {
    var serverURL: String
    var categories: [SponsorCategory]
    var minVotes: Int
    var isEnabled: Bool
    var autoSkip: Bool

    static let `default` = SponsorConfig(
        serverURL: "https://bsbsb.top/api",
        categories: [.sponsor, .selfpromo, .interaction, .filler],
        minVotes: -1,
        isEnabled: false,
        autoSkip: true
    )
}

extension SponsorSegment {
    func contains(time: Double) -> Bool {
        time >= startTime && time <= endTime
    }
}
