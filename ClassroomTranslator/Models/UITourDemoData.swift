import Foundation

/// task-12：CI 截图导览的演示数据 —— **启动参数门控，生产零执行**。
///
/// 这是 task-12 规格唯一授权的 App 侧改动：进程参数含 `-uiTestDemoData`
/// （XCUIApplication.launchArguments 注入）时，HistoryStore 初始化完成后
/// 一次性插入演示课程（每周一 14:00）+ 演示会话（老师/学生1 标签 +
/// 预置昵称「王教授」）。
///
/// 生产进程无该参数 → isEnabled 仅做一次数组扫描即返回 false，
/// 除这一行外整段代码路径不执行、零开销；带参数时幂等
/// （同名课程已存在即跳过，同 run 内重复 launch 不双写）。
enum UITourDemoData {
    /// 演示课程名 —— 同时是幂等键与 UI 断言锚点。
    static let courseName = "演示课程"
    /// 演示会话标题 —— SessionDisplay 非空标题原样显示，作 UI 断言锚点。
    static let recordTitle = "第一讲：光合作用"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestDemoData")
    }

    /// 幂等插入演示数据（仅 isEnabled 时有任何动作）。返回是否新插入。
    @discardableResult
    @MainActor
    static func seedIfNeeded(in historyStore: HistoryStore) -> Bool {
        guard isEnabled else { return false }
        guard !historyStore.courses.contains(where: { $0.name == courseName }) else { return false }

        // 排课：每周一 14:00（spec 截图 5 要求显示「每周一 14:00」）。
        let course = Course(
            name: courseName,
            accentCode: "en-US",
            targetLanguageCode: "zh-Hans",
            createdAt: Date()
        )
        course.scheduleType = CourseSchedule.weekly
        course.weeklyWeekday = 1 // ISO 1=周一
        course.scheduleHour = 14
        course.scheduleMinute = 0
        historyStore.addCourse(course)

        // 演示会话：两个说话人标签 + 预置昵称（spec 截图 6 要求含「王教授」）。
        let record = historyStore.startNewRecord(in: course, title: recordTitle)
        record.segments = [
            TranscriptSegment(
                original: "同学们，我们开始上课。今天讲光合作用。",
                translated: "Class, let's begin. Today we cover photosynthesis.",
                speaker: "老师"
            ),
            TranscriptSegment(
                original: "老师，光合作用的公式是什么？",
                translated: "Professor, what is the photosynthesis equation?",
                speaker: "学生1"
            ),
            TranscriptSegment(
                original: "二氧化碳加水，在光照下生成有机物和氧气。",
                translated: "CO2 plus water under light yields organics and oxygen.",
                speaker: "老师"
            )
        ]
        record.speakerNames = SpeakerAliases.encode([
            "老师": SpeakerAlias(nickname: "王教授", role: .professor),
            "学生1": SpeakerAlias(nickname: "小明", role: .student)
        ])
        // finishRecord = checkpoint + fetchCourses/fetchRecords：
        // 内存数组刷新后侧栏计数与详情列表立即可见（否则导览 05 断言查不到记录行）。
        historyStore.finishRecord(record, duration: 1860)
        return true
    }
}
