import XCTest
@testable import ClassroomTranslator

/// task-8：排课描述纯逻辑单测。
///
/// locale / timeZone / bundle 全部注入 —— 断言与 CI 系统区域设置无关：
/// - zh 用 .copy("Resources/zh-Hans.lproj") 资源 bundle 查表；
/// - en 无 en 表 → 回落 key（英文原文），同样确定；
/// - 时间固定 UTC，日期固定 2025-03-05 14:00（规格示例「3月5日 14:00」）。
final class CourseScheduleTests: XCTestCase {
    private let zh = Locale(identifier: "zh-Hans")
    private let en = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func describe(
        type: String?,
        weekday: Int? = nil,
        day: Int? = nil,
        hour: Int? = nil,
        minute: Int? = nil,
        single: Date? = nil,
        fallback: Date = Date(),
        locale: Locale
    ) -> String {
        CourseSchedule.describe(
            scheduleType: type,
            weeklyWeekday: weekday,
            monthlyDay: day,
            scheduleHour: hour,
            scheduleMinute: minute,
            singleDate: single,
            fallbackDate: fallback,
            locale: locale,
            timeZone: utc,
            bundle: CourseSchedule.stringsBundle
        )
    }

    /// 固定 2025-03-05 14:00 UTC。
    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2025
        components.month = 3
        components.day = 5
        components.hour = 14
        components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: components)!
    }

    // MARK: - 每周

    func testWeeklyZhExactMatch() {
        XCTAssertEqual(
            describe(type: CourseSchedule.weekly, weekday: 1, hour: 14, minute: 0, locale: zh),
            "每周一 14:00"
        )
    }

    func testWeeklyIso7IsSundayZh() {
        XCTAssertEqual(
            describe(type: CourseSchedule.weekly, weekday: 7, hour: 9, minute: 30, locale: zh),
            "每周日 09:30"
        )
    }

    func testWeeklyEnUsesKeyAndShortSymbol() {
        XCTAssertEqual(
            describe(type: CourseSchedule.weekly, weekday: 1, hour: 14, minute: 5, locale: en),
            "Every Mon at 14:05"
        )
    }

    // MARK: - 每月

    func testMonthlyZhExactMatch() {
        XCTAssertEqual(
            describe(type: CourseSchedule.monthly, day: 5, hour: 9, minute: 30, locale: zh),
            "每月5日 09:30"
        )
    }

    func testMonthlyDayClampedTo28() {
        // 31 号跨月问题 → clamp 到 28（规格）。
        XCTAssertEqual(
            describe(type: CourseSchedule.monthly, day: 31, hour: 8, minute: 0, locale: zh),
            "每月28日 08:00"
        )
    }

    // MARK: - 单次 / 老数据

    func testSingleZhDateTemplate() {
        let text = describe(type: CourseSchedule.single, single: fixedDate, locale: zh)
        XCTAssertTrue(text.contains("3月5日"), "expected 3月5日 in \(text)")
        XCTAssertTrue(text.contains("14:00"), "expected 14:00 in \(text)")
    }

    func testLegacyNilTypeMatchesSingle() {
        let legacy = describe(type: nil, single: fixedDate, locale: zh)
        let single = describe(type: CourseSchedule.single, single: fixedDate, locale: zh)
        XCTAssertEqual(legacy, single)
        XCTAssertTrue(legacy.contains("3月5日"))
    }

    func testLegacyNilTypeUsesFallbackCreatedAt() {
        let text = describe(type: nil, single: nil, fallback: fixedDate, locale: zh)
        XCTAssertTrue(text.contains("3月5日"), "nil 类型应按单次用 fallbackDate，got \(text)")
    }

    // MARK: - 防御：字段残缺兜底

    func testWeeklyMissingWeekdayFallsBackToSingle() {
        let text = describe(
            type: CourseSchedule.weekly, hour: 14, minute: 0, single: fixedDate, locale: zh
        )
        XCTAssertTrue(text.contains("3月5日"), "缺 weekday 应兜底单次，got \(text)")
    }

    func testWeekdayOutOfRangeFallsBackToSingle() {
        let text = describe(
            type: CourseSchedule.weekly, weekday: 0, hour: 14, minute: 0, single: fixedDate, locale: zh
        )
        XCTAssertTrue(text.contains("3月5日"), "非法 weekday 应兜底单次，got \(text)")
    }

    // MARK: - Course 包装属性

    func testCourseScheduleDescriptionUsesFields() {
        let course = Course(name: "Test", createdAt: fixedDate)
        course.scheduleType = CourseSchedule.weekly
        course.weeklyWeekday = 3
        course.scheduleHour = 10
        course.scheduleMinute = 15
        let text = course.scheduleDescription
        // 时间部分格式化与 locale 无关（24h 零填充），只断言它。
        XCTAssertTrue(text.contains("10:15"), "got \(text)")
    }
}
