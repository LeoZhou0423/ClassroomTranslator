import Foundation
import SwiftData

@Model
final class Course {
    var id: UUID
    var name: String
    var accentCode: String
    /// Optional for lightweight migration of courses created before this field existed.
    var targetLanguageCode: String?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \TranscriptRecord.course)
    var records: [TranscriptRecord]

    var accentName: String {
        LanguageOptions.name(for: accentCode)
    }

    var effectiveTargetLanguageCode: String {
        targetLanguageCode ?? "zh-Hans"
    }

    var targetLanguageName: String {
        LanguageOptions.name(for: effectiveTargetLanguageCode)
    }

    init(name: String, accentCode: String = "en-US", targetLanguageCode: String = "zh-Hans", createdAt: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.accentCode = accentCode
        self.targetLanguageCode = targetLanguageCode
        self.createdAt = createdAt
        self.records = []
    }
}
