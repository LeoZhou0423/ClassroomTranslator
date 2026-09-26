import XCTest
import AppKit

/// task-12：CI 截图导览 —— 7 张命名截图写入 ui-smoke-artifacts/gui-tour/。
///
/// 设计要点：
/// - **语言**：导览用 zh（`-appLanguage zh-Hans` 走 NSArgumentDomain ——
///   applyAppLanguage 每次启动以 defaults 的 appLanguage 覆盖 AppleLanguages，
///   后续 launch 自愈回 en，与既有 LingoclassUITests（EN 选择器）互不干扰）。
/// - **种数据**：`-uiTestDemoData` 启动参数门控（App 侧 UITourDemoData，幂等）。
/// - **单方法两段式**：Phase A 无种数据截 Home 空态，terminate 后 Phase B 带参
///   走 02…07 —— 顺序确定，不依赖 XCTest 方法排序。
/// - **失败口径**：任何断言/截图失败 → xcodebuild ** TEST FAILED ** →
///   分类器规则 a（硬失败优先）必红，不静默；采集为空或写盘失败同样 XCTFail。
/// - 导航断言沿用既有 5 条的健壮等待（waitForExistence + 多类型候选点击，
///   task-7 教训②③：AX 类型随 macOS/Xcode 版本漂移，不赌单一类型）。
final class ScreenshotTourTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.user.lingoclass")
    private var tourDir = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        // run 36236618462：沙箱 runner 写工作区 = NSCocoaErrorDomain 513 —— 写盘
        // 目标显式 = xctrunner 容器（实证可写；id 源头 UITests/project.yml:17 +
        // .xctrunner 后缀，与 run_xcuitests.sh 的 TOUR_CONTAINER_DIR 同值）。
        // shell 层 cp 搬运到 $OUT（三层闭环第 1 层）。env 优先、容器兜底。
        // NSUserName() 走 passwd（避开沙箱下 HOME/container 语义歧义，教训②）。
        let containerDir = "/Users/\(NSUserName())/Library/Containers/"
            + "com.user.lingoclass.uitests.xctrunner/Data/ui-smoke-artifacts/gui-tour"
        tourDir = env["LINGOCLASS_TOUR_DIR"] ?? containerDir
        print("TOUR_DIR: \(tourDir)")
        do {
            try FileManager.default.createDirectory(atPath: tourDir, withIntermediateDirectories: true)
        } catch {
            XCTFail("截图目录创建失败 \(tourDir): \(error)")
        }
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - helpers

    /// 等待存在（沿用既有测试的健壮等待口径）。
    private func wait(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(name) 未出现", file: file, line: line)
    }

    /// 多类型候选点第一个存在的（分段控件/行/按钮的 AX 类型会漂移）。
    private func tapFirst(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        // 分段 Picker：先看 segmentedControls 里的按钮子项。
        let segments = app.segmentedControls.buttons[label].firstMatch
        if segments.exists {
            segments.tap()
            return
        }
        let candidates = [
            app.buttons[label],
            app.radioButtons[label],
            app.staticTexts[label],
            app.menuItems[label]
        ]
        for candidate in candidates where candidate.exists {
            candidate.tap()
            return
        }
        XCTFail("无可点击候选: \(label)", file: file, line: line)
    }

    /// Form 分组内容可能在折叠线下，滚动到目标出现（复用既有口径）。
    private func scrollUntilVisible(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        if element.exists { return true }
        let scroller = app.scrollViews.firstMatch
        guard scroller.exists else { return false }
        for _ in 0..<maxSwipes {
            scroller.swipeUp()
            if element.exists { return true }
        }
        return element.exists
    }

    /// 侧栏固定行（设置/课程/全部录音 —— 列表顶部固定条目）：**双字段精确谓词**
    /// （label == OR value ==，run 36239878792：SwiftUI StaticText 的 AX 文本在
    /// value 字段、label 常空 —— 只查 label 会把设置行弄丢；精确等值同时保住
    /// 「课程」不子串误中「演示课程」）。行类型多候选 = task-7 教训②③。
    private func sidebarFixedRow(_ label: String) -> XCUIElement? {
        let exact = NSPredicate(format: "label == %@ OR value == %@", label, label)
        let candidates: [XCUIElement] = [
            app.outlineRows.matching(exact).firstMatch,
            app.descendants(matching: .tableRow).matching(exact).firstMatch,
            app.staticTexts.matching(exact).firstMatch
        ]
        for candidate in candidates where candidate.exists {
            return candidate
        }
        return nil
    }

    /// 点击侧栏固定行：解析后先打**完整 label/type/frame**（一行判位 —— 下轮
    /// 日志直接看清点的是「课程」还是「演示课程」），再 click。
    private func clickSidebarFixed(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let row = sidebarFixedRow(label) else {
            XCTFail("侧栏固定行「\(label)」不存在", file: file, line: line)
            return
        }
        print("TOUR_FIXED_ROW[\(label)]: type=\(row.elementType) frame=\(row.frame) label=\(row.label) value=\(String(describing: row.value)) debug=\(String(row.debugDescription.prefix(160)))")
        row.click()
    }

    /// 侧栏 Settings 行（zh=设置）。
    private func sidebarSettingsElement() -> XCUIElement? {
        return sidebarFixedRow("设置")
    }

    /// 侧栏课程行点击：先 staticText 点击；detail 未切换（无「新建录音」）时
    /// 再试行容器（outlineRow/tableRow，label 含课程名）—— task-7 教训②③口径。
    /// 最终是否切换由外层 wait(新建录音) 给统一失败点。
    private func tapSidebarCourse(_ name: String) {
        let text = app.staticTexts[name]
        if text.exists {
            print("TOUR_SIDEBAR_COURSE[\(name)]: label=\(text.label) value=\(String(describing: text.value)) frame=\(text.frame)")
            text.tap()
        }
        if app.buttons["新建录音"].waitForExistence(timeout: 4) { return }
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", name)
        // 行类型枚举只用 task-7 已编译过的两个（.row 在 macOS 26 被改名的教训②③）。
        let rowCandidates = [
            app.outlineRows.matching(predicate).firstMatch,
            app.descendants(matching: .tableRow).matching(predicate).firstMatch
        ]
        for row in rowCandidates where row.exists {
            row.tap()
            if app.buttons["新建录音"].waitForExistence(timeout: 6) { return }
        }
    }

    /// 记录行：staticText 精确 → 按钮 label CONTAINS 兜底
    ///（macOS Button 的复杂 label 可能不暴露子 staticText）。
    private func recordRowElement(_ title: String) -> XCUIElement {
        let text = app.staticTexts[title]
        if text.exists { return text }
        return app.descendants(matching: .button)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
    }

    /// 会话 sheet 是否已打开（完成/编辑/段落译文任一 —— 浏览态铁证组合）。
    private func sheetSessionOpen() -> Bool {
        return app.buttons["完成"].exists
            || app.buttons["编辑"].exists
            || app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "photosynthesis"))
                .firstMatch.exists
    }

    /// 记录行点击（06 专用，run 36237124773 第八轮升级）：
    /// ① 判位打印：debugDescription 前 200 字（可读类型名）+ frame + isEnabled；
    /// ② 每步后查 sheets.count / windows.count —— 计数变了但内容三合一不在 =
    ///    sheet 开了但内容空（转层②），计数不变 = 真没开；
    /// ③ 中心坐标 tap → doubleClick → 文本坐标 tap → Return 键（macOS 列表
    ///    『选中后回车打开』惯例 / Button 焦点态 Enter=click）。
    private func clickRecordRow(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.descendants(matching: .button)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        let text = app.staticTexts[title]
        let target: XCUIElement = button.exists ? button : text
        guard target.exists else {
            lastRowTargetInfo = "(button/text 皆无)"
            XCTFail("记录行候选不存在", file: file, line: line)
            return
        }
        lastRowTargetInfo = "type=\(target.elementType) frame=\(target.frame) enabled=\(target.isEnabled) debug=\(String(target.debugDescription.prefix(200)))"
        print("TOUR_ROW_TARGET: \(lastRowTargetInfo)")
        let sheetsBefore = app.sheets.count
        let windowsBefore = app.windows.count
        print("TOUR_ROW_SHEETS: before sheets=\(sheetsBefore) windows=\(windowsBefore)")

        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if probeRowClick(step: "coordinate-tap", sheetsBefore: sheetsBefore, windowsBefore: windowsBefore) { return }
        target.doubleClick()
        if probeRowClick(step: "doubleClick", sheetsBefore: sheetsBefore, windowsBefore: windowsBefore) { return }
        if text.exists, target !== text {
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if probeRowClick(step: "text-coordinate-tap", sheetsBefore: sheetsBefore, windowsBefore: windowsBefore) { return }
        }
        print("TOUR_ROW_RETRY: press return")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        if probeRowClick(step: "press-return", sheetsBefore: sheetsBefore, windowsBefore: windowsBefore) { return }
        print("TOUR_ROW_CLICK_FAILED: \(lastRowTargetInfo)")
    }

    /// 每步点击后的探针：打印 sheets/windows 计数变化；内容三合一开（真开）或
    /// 计数增长（开但内容空 → 层①/② 接手判定）都算『已打开』停止重试。
    private func probeRowClick(step: String, sheetsBefore: Int, windowsBefore: Int) -> Bool {
        let sheetsNow = app.sheets.count
        let windowsNow = app.windows.count
        let contentOpen = sheetSessionOpen()
        print("TOUR_ROW_PROBE[\(step)]: sheets \(sheetsBefore)->\(sheetsNow) windows \(windowsBefore)->\(windowsNow) contentOpen=\(contentOpen)")
        return contentOpen || sheetsNow > sheetsBefore
    }

    /// 上一次记录行命中的 element 描述（层①判A 文案用）。
    private var lastRowTargetInfo = "(unresolved)"

    /// 等待 App 进程真正退出（两段式重启的衔接）。
    private func waitAppExit(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.user.lingoclass").isEmpty {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    /// 采一张命名截图并写盘；采集或写入失败 = 断言失败（截图失败=红，不静默）。
    private func snap(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let shot = XCUIScreen.main.screenshot()
        // 此 SDK 的 pngRepresentation 返回**非可选** Data（run 36232599445 编译错教训）。
        let data = shot.pngRepresentation
        guard !data.isEmpty else {
            XCTFail("截图 \(name) 采集为空（pngRepresentation empty，疑 TCC）", file: file, line: line)
            return
        }
        let path = (tourDir as NSString).appendingPathComponent(name)
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("TOUR_SHOT: \(path) (\(data.count) bytes)")
        } catch {
            XCTFail("截图 \(name) 写入失败: \(error)", file: file, line: line)
        }
    }

    // MARK: - 导览主体

    func testGuidedScreenshotTour() {
        // ---- Phase A：无种数据 → 01 Home 空态（zh）----
        app.launchEnvironment["LINGOCLASS_TOUR_DIR"] = tourDir
        app.launchArguments = ["-appLanguage", "zh-Hans"]
        app.launch()
        wait(app.windows.firstMatch, "主窗口")
        wait(app.staticTexts["课程"], "侧栏「课程」锚点")
        snap("01-home.png")

        // ---- 重启进 Phase B：种数据门控开 ----
        app.terminate()
        XCTAssertTrue(waitAppExit(), "Phase A 进程未在时限内退出")
        app.launchArguments = ["-appLanguage", "zh-Hans", "-uiTestDemoData"]
        app.launch()
        wait(app.windows.firstMatch, "主窗口（Phase B）")

        // ---- 02：新建课程表单 · 单次模式（默认态）----
        wait(app.buttons["新建课程"], "新建课程工具条按钮")
        app.buttons["新建课程"].tap()
        wait(app.staticTexts["课程信息"], "New Course 表单（Course Info 锚点）")
        wait(app.staticTexts["日期和时间"], "单次模式 DatePicker 标签")
        snap("02-new-course-single.png")

        // ---- 03：每周模式（星期 + 时间控件）----
        tapFirst("每周")
        wait(app.staticTexts["星期几"], "每周模式 Weekday Picker")
        wait(app.staticTexts["时间"], "每周模式 Time DatePicker")
        snap("03-new-course-weekly.png")

        // ---- 04：每月模式（Stepper + 时间）----
        tapFirst("每月")
        wait(app.staticTexts["每月几号"], "每月模式 Stepper（Day of Month）")
        wait(app.staticTexts["时间"], "每月模式 Time DatePicker")
        snap("04-new-course-monthly.png")

        // 关表单回 Home。
        wait(app.buttons["取消"], "表单取消按钮")
        app.buttons["取消"].tap()
        wait(app.staticTexts["课程"], "回 Home 侧栏锚点")

        // ---- 05：课程详情（排课描述「每周一 14:00」）----
        wait(app.staticTexts["演示课程"], "演示课程侧栏行")
        tapSidebarCourse("演示课程")
        // 诊断细分①：detail 切换铁证 = CourseDetailView 独有「新建录音」按钮
        //（coursesOverview 只有「请从侧边栏选择课程」—— 点击未选中会停在那里）。
        wait(app.buttons["新建录音"], "detail 切换（新建录音按钮）—— 缺 = 侧栏行点击未选中")
        // 诊断细分②：记录行 staticText → 按钮 label CONTAINS 兜底（macOS 按钮行
        // 可能不暴露子 staticText —— run 36233001709 卡点嫌疑）；仍缺失时用
        // 空态可见性把「种子/刷新问题」与「行 AX 选择器问题」切开。
        let recordRow = recordRowElement("第一讲：光合作用")
        if !recordRow.waitForExistence(timeout: 15) {
            let emptyVisible = app.staticTexts["暂无录音"].exists
            XCTFail("detail 已切换但记录行查不到（空态「暂无录音」可见=\(emptyVisible)）—— 可见 = 种子/内存刷新问题；不可见 = 行 AX 选择器问题")
        }
        wait(app.staticTexts["每周一 14:00"], "排课描述「每周一 14:00」")
        snap("05-course-detail.png")

        // ---- 07：设置页（引擎选择器 / 说话人标签 / 关于）----
        // 第八轮重排（lead）：设置无 sheet 依赖 —— 挪到 06 之前，06 迭代期间
        // 先攒 6/7 张（Verify ≥7 阈值不动，06 卡则仍红）。
        guard let settingsRow = sidebarSettingsElement() else {
            XCTFail("侧栏 Settings（设置）行不存在")
            return
        }
        settingsRow.click()
        wait(app.staticTexts["App 语言"], "Settings 页锚点（App Language）")
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["语音引擎"]), "语音引擎 Section 应可达")
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["说话人标签"]), "说话人标签 Section 应可达")
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["关于"]), "关于（About）应可达")
        snap("07-settings.png")

        // 回课程详情（06 前置，run 36238309642 卡点）—— 侧栏 ping-pong 两跳：
        // ① 先点固定顶行「课程」强制 selection 变化（.settings→.courses，铁证 =
        //    「请从侧边栏选择课程」；macOS List 还会把选中行滚入视口 —— 若 07 的
        //    滚动把课程行带出视口，这一步把它带回来）；
        // ② 再点课程行（.courses→.course 再变一次），等待提到 15s。
        clickSidebarFixed("课程")
        // hop1 锚（读码重挑，run 36239878792）：coursesOverview **非空分支**（种子
        // 保证有课 → 必走 else，L156-160）独有两行指引文本，与空态无关（空分支
        // No Courses Yet 在种子流程不可能出现）；两行 OR 兜措辞漂移。
        // 反证 lead 例示的「新建课程」按钮：它在工具条（HomeView L57-61 挂侧栏
        // List 的 toolbar，**各页全局可见**）—— 不是 overview 独有，当锚会假通过。
        // 反向排除：「新建录音」= 课程详情独有。状态恒打印，成败都留证据。
        let overviewGuidance = NSPredicate(
            format: "value == %@ OR value == %@ OR label == %@ OR label == %@",
            "请从侧边栏选择课程", "每次新录音都会保存为独立转录记录。",
            "请从侧边栏选择课程", "每次新录音都会保存为独立转录记录。")
        let overviewShown = app.staticTexts.matching(overviewGuidance).firstMatch
            .waitForExistence(timeout: 10)
        let onCourseDetail = app.buttons["新建录音"].exists
        let onSettings = app.staticTexts["App 语言"].exists
        print("TOUR_HOP1_STATE: 指引锚=\(overviewShown) 新建录音=\(onCourseDetail) App语言=\(onSettings)")
        if !overviewShown && (onCourseDetail || onSettings) {
            // 指引没出但人还在课程详情/设置页 → selection 没走到 .courses。
            XCTFail("回课程总览失败（指引锚未出；新建录音=\(onCourseDetail) App语言=\(onSettings)）")
        }
        if !overviewShown {
            // 反向通过：既不在课程详情也不在设置页 → 认定总览（留证）。
            print("TOUR_HOP1_INV: no guidance but not on detail/settings — treated as overview")
        }
        tapSidebarCourse("演示课程")
        wait(app.buttons["新建录音"], "从设置返回课程详情（新建录音按钮）", timeout: 15)

        // ---- 06：会话详情（人员区 + 预置昵称王教授 + 可编辑标题/日期）----
        // 实际断言顺序：人员区/昵称在**浏览态**先断，编辑态标题/日期在后。
        // 分层诊断（run 36233690741 卡 215 的三层切分）：
        // 层① sheet 打开（判别位切 A=点击没生效 / B=「完成」浏览态锚点假阴性）：
        // 编辑按钮/段落译文任一可见 = sheet 其实开了 → 换锚继续不红；都不可见 = A。
        clickRecordRow("第一讲：光合作用")
        if !app.buttons["完成"].waitForExistence(timeout: 10) {
            let editVisible = app.buttons["编辑"].exists
            // Query 没有 exists（只有 element 有 —— 教训②变体），firstMatch 上取。
            let segVisible = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "photosynthesis")).firstMatch.exists
            let sheetsNow = app.sheets.count
            if editVisible || segVisible {
                print("TOUR_LAYER1_B: sheet open, 完成 anchor false-negative (edit=\(editVisible) seg=\(segVisible))")
            } else if sheetsNow > 0 {
                // 计数变了但内容三合一不在 = sheet 开了但内容空 —— 转层②判定，不红这里。
                print("TOUR_LAYER1_EMPTY: sheets=\(sheetsNow) but no content — 转层②")
            } else {
                XCTFail("层①判A：点击没生效 —— 无「完成」、无「编辑」、无段落译文、sheets=0，sheet 未开（target: \(lastRowTargetInfo)）")
            }
        }
        // 层② segments 落库铁证 = 第 1 段**英文译文**关键词（行预览 fullTranscript
        // 只含 zh 原文、标题/侧栏皆无 → 背景零泄漏；第 1 段在列表顶部必物化
        // （LazyVStack 折线以下的第 3 段关键词会假失败，已避开）。
        let segText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "photosynthesis")).firstMatch
        if !segText.waitForExistence(timeout: 10) {
            XCTFail("层② sheet 已开但段落译文不可见 —— 种子 segments 未落库/未渲染（嫌疑2）")
        }
        // 层③ 段落在 →「人员」Section 应在（浏览态渲染、不门控编辑态；无标签才按设计隐藏）。
        // 判别位：段落昵称「王教授」——可见 = 标签/昵称数据在、Section 该显示（→1/4）；
        // 不可见 = speaker/昵称数据空 → uniqueSpeakerLabels=[] → 按设计隐藏（→种子嫌疑5）。
        if !app.staticTexts["人员"].waitForExistence(timeout: 10) {
            let wangVisible = app.staticTexts["王教授"].exists
            let editButtonVisible = app.buttons["编辑"].exists
            XCTFail("层③ 段落在但「人员」查不到（段落昵称「王教授」可见=\(wangVisible)，不可见=标签/昵称数据空、Section 按设计隐藏；编辑按钮可见=\(editButtonVisible)）")
        }
        wait(app.staticTexts["王教授"], "预置昵称「王教授」（段落显示）")
        wait(app.textFields["昵称"], "昵称输入")
        // 进编辑态：标题 TextField + 日期控件（规格 6 要求的「可编辑标题+日期控件」）。
        wait(app.buttons["编辑"], "Edit 按钮")
        app.buttons["编辑"].tap()
        wait(app.textFields["录音标题"], "编辑态标题输入")
        let datePickers = app.datePickers.firstMatch
        wait(datePickers, "编辑态日期控件")
        // 人员区昵称字段的值 = 王教授（预置映射的可视化演示）。
        let wangValue = app.textFields.matching(NSPredicate(format: "value == %@", "王教授")).firstMatch
        XCTAssertTrue(wangValue.waitForExistence(timeout: 5), "昵称字段应显示「王教授」")
        snap("06-session-detail.png")

        // ---- 收尾：退出编辑态 → 关 sheet（07 设置已在前执行）----
        wait(app.buttons["取消"], "编辑态取消按钮（退出编辑）")
        app.buttons["取消"].tap()
        // 关 sheet：「完成」优先；缺席（层①判B 情形）→ Escape 兜底。
        if app.buttons["完成"].exists {
            app.buttons["完成"].tap()
        } else {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        }

        print("TOUR_DONE dir=\(tourDir)")
    }
}
