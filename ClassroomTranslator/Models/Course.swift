import Foundation
import SwiftData

@Model
final class Course {
    var id: UUID
    var name: String
    var accentCode: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \TranscriptRecord.course)
    var records: [TranscriptRecord]

    var accentName: String {
        let map: [String: String] = [
            "en-US": "American", "en-GB": "British", "en-AU": "Australian",
            "en-NZ": "New Zealand", "en-IE": "Irish", "en-ZA": "South African",
            "en-CA": "Canadian", "en-IN": "Indian", "zh-Hans": "Chinese",
            "ja-JP": "Japanese", "ko-KR": "Korean"
        ]
        return map[accentCode] ?? accentCode
    }

    init(name: String, accentCode: String = "en-US", createdAt: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.accentCode = accentCode
        self.createdAt = createdAt
        self.records = []
    }
}
