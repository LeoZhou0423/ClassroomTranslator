import XCTest

/// task-7 阶段 2：真 UI 断言（5 条，与任务规格逐条对应）。
///
/// 前置：run_xcuitests.sh 已 `defaults write com.user.lingoclass appLanguage en` 强制英文 UI
/// （App 默认 zh-Hans，文本选择器依赖英文）；LingoClass.app 已装 /Applications。
/// 纪律：禁用录音流程 —— 麦克风 TCC 按钮点了会卡权限弹窗，全部测试不得进入录音页。
final class LingoclassUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.user.lingoclass")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    /// 侧栏 Settings 入口：List 行在 AX 树里的类型因 macOS/Xcode 版本可能是
    /// outlineRow / row / staticText，按顺序找第一个存在的。
    private func sidebarSettingsElement() -> XCUIElement? {
        let candidates = [
            app.outlineRows["Settings"],
            app.rows["Settings"],
            app.staticTexts["Settings"]
        ]
        for candidate in candidates where candidate.exists {
            return candidate
        }
        return nil
    }

    /// Settings 是 detail 列（非 sheet）；锚点 = Form 顶部 "App Language" 组头。
    private func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = sidebarSettingsElement() else {
            XCTFail("侧栏 Settings 行不存在", file: file, line: line)
            return
        }
        entry.click()
        let anchor = app.staticTexts["App Language"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 10), "Settings 页未打开（缺 App Language 锚点）", file: file, line: line)
    }

    /// Form 分组页内容可能在窗口折叠线下，滚动到目标出现。
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

    // 1) 主窗口存在
    func testMainWindowExists() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "主窗口应存在")
    }

    // 2) 侧栏可见（NavigationSplitView 的两个固定入口）
    func testSidebarVisible() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Courses"].waitForExistence(timeout: 10), "侧栏 Courses 应可见")
        XCTAssertTrue(app.staticTexts["All Recordings"].waitForExistence(timeout: 10), "侧栏 All Recordings 应可见")
    }

    // 3) Settings 打开（侧栏点击 → detail 列出现 Form）
    func testSettingsOpens() {
        openSettings()
        XCTAssertNotNil(sidebarSettingsElement(), "进入 Settings 后侧栏仍应存在")
    }

    // 4) Speech Engine Picker 显示 Apple SpeechAnalyzer
    func testSpeechEnginePickerShowsApple() {
        openSettings()
        let section = app.staticTexts["Speech Engine"]
        XCTAssertTrue(scrollUntilVisible(section), "Speech Engine Section 应可达")
        // Picker 选项与 About 行同文案，出现任一即证明默认引擎为 Apple。
        let apple = app.staticTexts["Apple SpeechAnalyzer"]
        XCTAssertTrue(scrollUntilVisible(apple), "应显示 Apple SpeechAnalyzer")
    }

    // 5) 说话人设置 Section 存在
    func testSpeakerLabelsSectionExists() {
        openSettings()
        let section = app.staticTexts["Speaker Labels"]
        XCTAssertTrue(scrollUntilVisible(section), "说话人设置 Section 应存在")
    }
}
