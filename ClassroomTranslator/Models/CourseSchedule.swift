import Foundation

/// task-8：课程排课（每周/每月/单次）的纯逻辑 —— 描述文案生成与类型常量。
///
/// - 全部输入为可选原始值，locale / timeZone / bundle 可注入 → 单测确定性
///   （不依赖 CI 系统区域设置）；
/// - 老课程 scheduleType == nil → 按 single 用 createdAt 兜底，零数据丢失；
/// - 每月天数 clamp 1–28：29/30/31 号在小月会跨月，产品上统一取 28
///   （NewCourseView Stepper 同步限制 1...28，这里再 clamp 一次做防御）。
enum CourseSchedule {
    static let single = "single"
    static let weekly = "weekly"
    static let monthly = "monthly"

    /// 生产走 Bundle.main（与 SwiftUI Text 默认一致，zh 已实测可用）；
    /// 单测注入 .module（Package.swift .copy("Resources/zh-Hans.lproj")）。
    static let stringsBundle: Bundle = .module

    /// 课程排课描述：「每周一 14:00」「每月5日 09:30」「3月5日 14:00」（zh-Hans）。
    /// - Parameters:
    ///   - fallbackDate: scheduleType 为 nil 或字段残缺时按 single 展示的日期（课程传 createdAt）。
    ///   - bundle: 文案查表的 bundle；nil = Bundle.main（生产）。
    static func describe(
        scheduleType: String?,
        weeklyWeekday: Int?,
        monthlyDay: Int?,
        scheduleHour: Int?,
        scheduleMinute: Int?,
        singleDate: Date?,
        fallbackDate: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        bundle: Bundle? = nil
    ) -> String {
        let textBundle = bundle ?? .main
        switch scheduleType {
        case weekly:
            if let weekday = weeklyWeekday, (1...7).contains(weekday),
               let hour = scheduleHour, let minute = scheduleMinute {
                let time = timeString(hour: hour, minute: minute)
                let day = weekdaySymbol(isoWeekday: weekday, locale: locale)
                return String(
                    format: String(localized: "Every %1$@ at %2$@", bundle: textBundle, locale: locale),
                    day, time
                )
            }
            return describeSingle(singleDate ?? fallbackDate, locale: locale, timeZone: timeZone)
        case monthly:
            if let day = monthlyDay, let hour = scheduleHour, let minute = scheduleMinute {
                let clamped = min(max(day, 1), 28)
                let time = timeString(hour: hour, minute: minute)
                return String(
                    format: String(localized: "Monthly on day %1$@ at %2$@", bundle: textBundle, locale: locale),
                    String(clamped), time
                )
            }
            return describeSingle(singleDate ?? fallbackDate, locale: locale, timeZone: timeZone)
        default:
            // "single" 与老数据 nil 都走这里；singleDate 缺失时退回 fallbackDate。
            return describeSingle(singleDate ?? fallbackDate, locale: locale, timeZone: timeZone)
        }
    }

    /// ISO 星期符号：1=周一 … 7=周日；Calendar.weekdaySymbols 0=周日 … 6=周六，
    /// 所以索引 = iso % 7（1→1 "周一"，7→0 "周日"）。符号取 short
    /// （zh-Hans: "周一"，en: "Mon"）。
    static func weekdaySymbol(isoWeekday: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.shortWeekdaySymbols[isoWeekday % 7]
    }

    /// 24 小时制零填充，对齐规格示例「14:00」「09:30」（locale 无关）。
    private static func timeString(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", Int32(hour), Int32(minute))
    }

    private static func describeSingle(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        // 本地化日期模板：zh-Hans → 「3月5日 14:00」，en → 「3/5, 2:00 PM」。
        formatter.setLocalizedDateFormatFromTemplate("MdHm")
        return formatter.string(from: date)
    }
}

extension Course {
    /// 排课描述（侧栏课程列表 + 课程详情共用；老数据回退 single 用 createdAt）。
    var scheduleDescription: String {
        CourseSchedule.describe(
            scheduleType: scheduleType,
            weeklyWeekday: weeklyWeekday,
            monthlyDay: monthlyDay,
            scheduleHour: scheduleHour,
            scheduleMinute: scheduleMinute,
            singleDate: singleDate,
            fallbackDate: createdAt
        )
    }
}
