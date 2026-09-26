import XCTest
@testable import ClassroomTranslator

/// VIS-09 / UX-07：计时格式统一与"取消不是错误"都是纯逻辑，可在 Windows 之外的 CI 上跑。
final class ExportFormatTests: XCTestCase {
    func testDurationUsesHoursMinutesSecondsEverywhere() {
        // VIS-09：三处（录音页 / 历史列表 / 导出文本）必须同为 h:mm:ss，
        // 否则同一条 1:05 的课会显示成 "0:05" 和 "5" 两种形态。
        XCTAssertEqual(ExportManager.formatDuration(0), "0:00:00")
        XCTAssertEqual(ExportManager.formatDuration(5), "0:00:05")
        XCTAssertEqual(ExportManager.formatDuration(65), "0:01:05")
        XCTAssertEqual(ExportManager.formatDuration(3_725), "1:02:05")
        XCTAssertEqual(ExportManager.formatDuration(36_000), "10:00:00")
    }

    func testDurationNeverGoesNegative() {
        // 录音中断/时钟回拨可能给出负值，"%02d" 会显示 "-01" 这类字串。
        XCTAssertEqual(ExportManager.formatDuration(-5), "0:00:00")
        XCTAssertEqual(ExportManager.formatDuration(-0.5), "0:00:00")
    }

    func testCancellationIsNotTreatedAsFailure() {
        // UX-07：只有 .cancelled 返回 true，其余失败与无关错误都必须照常上报。
        XCTAssertTrue(ExportManager.isCancellation(ExportManager.ExportError.cancelled))
        XCTAssertFalse(ExportManager.isCancellation(ExportManager.ExportError.unableToCreateDocument))
        XCTAssertFalse(ExportManager.isCancellation(ExportManager.ExportError.archiveFailed))
        XCTAssertFalse(ExportManager.isCancellation(NSError(domain: "test", code: 1)))
    }
}
