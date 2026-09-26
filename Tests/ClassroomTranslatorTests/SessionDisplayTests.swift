import XCTest
@testable import ClassroomTranslator

/// task-9：标题回退纯函数（SessionDisplay.titleText）单测。
/// locale / timeZone 注入 —— 断言与 CI 系统区域无关。
final class SessionDisplayTests: XCTestCase {
    private let zh = Locale(identifier: "zh-Hans")
    private let en = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    /// 固定 2025-03-05 14:00 UTC。
    private var marchFifth: Date {
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

    private func title(_ raw: String, locale: Locale) -> String {
        SessionDisplay.titleText(title: raw, date: marchFifth, locale: locale, timeZone: utc)
    }

    func testNonEmptyTitleReturnedTrimmed() {
        XCTAssertEqual(title("  第一讲  ", locale: zh), "第一讲")
    }

    func testInternalSpacesPreserved() {
        XCTAssertEqual(title("期中 考试", locale: zh), "期中 考试")
    }

    func testEmptyTitleFallsBackToDateZh() {
        XCTAssertEqual(title("", locale: zh), "3月5日")
    }

    func testWhitespaceOnlyTitleFallsBackToDateZh() {
        XCTAssertEqual(title("  \n\t ", locale: zh), "3月5日")
    }

    func testFallbackDateTemplateEn() {
        XCTAssertEqual(title("", locale: en), "3/5")
    }

    func testLegacyRecordEmptyTitleIsCoveredByFallback() {
        // 老数据零迁移：title "" 直接走占位，不依赖任何字段变更。
        let record = TranscriptRecord(date: marchFifth, title: "")
        XCTAssertEqual(
            SessionDisplay.titleText(title: record.title, date: record.date, locale: zh, timeZone: utc),
            "3月5日"
        )
    }
}
