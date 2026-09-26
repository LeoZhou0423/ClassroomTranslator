import Foundation

/// task-9：会话（TranscriptRecord）标题回退的纯逻辑。
///
/// 用户需求②：小项无名可改、空名要能区分 —— 标题 trim 后非空用标题，
/// 空/仅空白 → 本地化「M月d日」占位（老数据 title "" 直接走这里，零迁移）。
/// locale / timeZone 可注入 → 单测与 CI 系统区域无关。
enum SessionDisplay {
    /// 列表行 / 详情页标题：非空标题（去首尾空白），否则日期占位。
    static func titleText(
        title: String,
        date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallbackDate(date, locale: locale, timeZone: timeZone)
        }
        return trimmed
    }

    /// 占位日期：zh 手排「3月5日」（无年）—— 与 CourseSchedule.describeSingle 同因：
    /// macOS 26 工具链的 DateFormatter 模板在测试进程落 root 模式（run 36229026246：
    /// 注入 zh 输出 "3/5 14:00"），绕开它；非 zh 走模板（en → 「3/5」，CI 实测稳定）。
    private static func fallbackDate(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        if locale.language.languageCode?.identifier == "zh" {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.month, .day], from: date)
            return "\(parts.month ?? 1)月\(parts.day ?? 1)日"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter.string(from: date)
    }
}
