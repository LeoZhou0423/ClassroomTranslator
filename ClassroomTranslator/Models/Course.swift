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

    // task-8 排课：全部可选字段，nil = 老课程（SwiftData 轻量迁移，零数据丢失）。
    /// "weekly" / "monthly" / "single"；nil（老课程）按 single 处理。
    var scheduleType: String?
    /// 每周几（ISO 约定：1=周一 … 7=周日）。仅 scheduleType == "weekly"。
    var weeklyWeekday: Int?
    /// 每月几号 1–28 —— 29/30/31 号在小月会跨月，产品上统一 clamp 到 28
    /// （NewCourseView Stepper 限制 1...28，CourseSchedule.describe 再 clamp 一次做防御）。
    /// 仅 scheduleType == "monthly"。
    var monthlyDay: Int?
    /// 上课时间（24 小时制）。仅 weekly / monthly。
    var scheduleHour: Int?
    var scheduleMinute: Int?
    /// 单次课程的日期时间。仅 scheduleType == "single"。
    var singleDate: Date?

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
