import Foundation

struct SubtitlePair: Equatable {
    let id: UUID?
    let original: String
    let translated: String
    let speaker: String?
}
