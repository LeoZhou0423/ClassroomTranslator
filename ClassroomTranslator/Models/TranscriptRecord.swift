import Foundation
import SwiftData

@Model
final class TranscriptRecord {
    var id: UUID
    var date: Date
    var title: String
    var segmentsData: Data
    var duration: TimeInterval
    var course: Course?

    var segments: [TranscriptSegment] {
        get {
            guard !segmentsData.isEmpty,
                  let decoded = try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData) else {
                return []
            }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                segmentsData = encoded
            }
        }
    }

    init(date: Date = Date(), title: String = "", segments: [TranscriptSegment] = [], duration: TimeInterval = 0) {
        self.id = UUID()
        self.date = date
        self.title = title
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
        self.duration = duration
    }

    var fullTranscript: String {
        segments.map { $0.original }.joined(separator: " ")
    }

    var fullTranslation: String {
        segments.map { $0.translated }.joined(separator: " ")
    }

    var bilingualTranscript: String {
        segments.map { segment in
            "\(segment.original)\n\(segment.translated)"
        }.joined(separator: "\n\n")
    }
}

struct TranscriptSegment: Codable, Identifiable, Sendable {
    let id: UUID
    let original: String
    let translated: String
    let timestamp: Date
    let isFinal: Bool

    init(original: String, translated: String = "", timestamp: Date = Date(), isFinal: Bool = true) {
        self.id = UUID()
        self.original = original
        self.translated = translated
        self.timestamp = timestamp
        self.isFinal = isFinal
    }
}
