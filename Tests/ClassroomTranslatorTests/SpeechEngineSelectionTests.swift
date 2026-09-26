import XCTest
@testable import ClassroomTranslator

/// task-6：引擎选择的纯逻辑（key/默认值/可用性回退/工厂实例化）。
/// Step 1：任何已存值都解析为 Apple —— 默认行为零变化。
/// Step 2：sherpa 可用性 = 模型资源齐全（Bundle 注入覆盖缺失路径），
/// 工厂在缺失时回退 apple；真实模型创建在 CI 无麦跑通 C 层全链路。
final class SpeechEngineSelectionTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SpeechEngineSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    /// 空临时目录当“模型资源包”：文件缺失路径注入。
    private func makeEmptyBundle() throws -> (Bundle, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SherpaModelStub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = try XCTUnwrap(Bundle(url: dir))
        return (bundle, dir)
    }

    func testDefaultsKeyMatchesAppStorageLiteral() {
        // SettingsView 的 @AppStorage 用字面量 "speechEngine" —— 常量必须与之一致。
        XCTAssertEqual(SpeechEngineKind.defaultsKey, "speechEngine")
        XCTAssertEqual(SpeechEngineKind.fallback, .apple)
        XCTAssertEqual(SpeechEngineKind.fallback.rawValue, "apple")
    }

    func testUnstoredChoiceIsApple() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let kind = SpeechEngineKind(userDefaults: defaults)
        XCTAssertEqual(kind, .apple)
        XCTAssertEqual(kind.resolved, .apple)
    }

    func testStoredAppleStaysApple() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("apple", forKey: SpeechEngineKind.defaultsKey)
        XCTAssertEqual(SpeechEngineKind(userDefaults: defaults), .apple)
        XCTAssertTrue(SpeechEngineKind(userDefaults: defaults).isAvailable)
    }

    func testSherpaAvailableWhenModelPresent() {
        // Step 2：模型随包（Package.swift .copy SherpaStreamEN）→ sherpa 可用。
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("sherpa", forKey: SpeechEngineKind.defaultsKey)
        let kind = SpeechEngineKind(userDefaults: defaults)
        XCTAssertEqual(kind, .sherpa)
        XCTAssertTrue(kind.isAvailable, "测试环境应含 SherpaStreamEN 资源")
        XCTAssertEqual(kind.resolved, .sherpa)
    }

    func testUnknownValueFallsBackToApple() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("gpt4-realtime", forKey: SpeechEngineKind.defaultsKey)
        XCTAssertEqual(SpeechEngineKind(userDefaults: defaults), .apple)
    }

    func testFactoryReturnsAppleForNonSherpaChoices() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in ["", "apple", "garbage"] {
            defaults.set(value, forKey: SpeechEngineKind.defaultsKey)
            let engine = SpeechEngineFactory.make(userDefaults: defaults)
            XCTAssertTrue(engine is AppleSpeechEngine, "stored=\(value) 应返回 AppleSpeechEngine")
        }
    }

    func testFactorySherpaFallsBackWhenModelMissing() throws {
        // 降级纪律（同 task-4 模型缺失回退）：资源不齐 → 工厂直接出 apple，
        // sherpa 任何故障不触碰默认路径。
        let (bundle, dir) = try makeEmptyBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(SherpaSpeechEngine.modelsPresent(bundle: bundle))
        XCTAssertFalse(SherpaSpeechEngine.isUsable(bundle: bundle))

        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("sherpa", forKey: SpeechEngineKind.defaultsKey)
        let engine = SpeechEngineFactory.make(userDefaults: defaults, bundle: bundle)
        XCTAssertTrue(engine is AppleSpeechEngine, "模型缺失必须回退 AppleSpeechEngine")
    }

    func testFactorySherpaReturnsSherpaEngineWhenModelsPresent() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("sherpa", forKey: SpeechEngineKind.defaultsKey)
        let engine = SpeechEngineFactory.make(userDefaults: defaults)
        XCTAssertTrue(engine is SherpaSpeechEngine)
        XCTAssertFalse(engine.running, "init 必须轻量：不触麦克风、不创建识别器")
    }

    func testSherpaModelFilesRejectMissingAndTruncated() throws {
        // makeRecognizer 的最小体积防线（wrapper 对 C 失败是 trap 不是 nil）。
        let (bundle, dir) = try makeEmptyBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modelDir = dir.appendingPathComponent(SherpaSpeechEngine.modelDirectory)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        // 目录存在但无文件 → 缺失。
        XCTAssertFalse(SherpaSpeechEngine.modelsPresent(bundle: bundle))
        XCTAssertNil(SherpaSpeechEngine.makeRecognizer(modelDir: modelDir))
        // 文件名齐全但体积不足（截断/占位）→ 同样拒绝。
        for file in SherpaSpeechEngine.requiredModelFiles {
            try Data(repeating: 0, count: 8)
                .write(to: modelDir.appendingPathComponent(file.name))
        }
        XCTAssertFalse(SherpaSpeechEngine.modelsPresent(bundle: bundle))
        XCTAssertNil(SherpaSpeechEngine.makeRecognizer(modelDir: modelDir))
    }

    func testMakeRecognizerCreatesRealModelEndToEnd() throws {
        // CI 无麦全链路：真实 73.6MB 模型 → config → C 创建 → 释放。
        // 这是 sherpa 集成的运行时守门（编译守门由 import SherpaOnnx 承担）。
        let dir = try XCTUnwrap(SherpaSpeechEngine.modelDirectoryURL())
        guard SherpaSpeechEngine.modelsPresent() else {
            throw XCTSkip("SherpaStreamEN 资源不在测试 bundle，跳过")
        }
        let recognizer = SherpaSpeechEngine.makeRecognizer(modelDir: dir)
        XCTAssertNotNil(recognizer, "真实模型必须能创建识别器（含端点配置）")
        // 不 start()：识别器创建与麦克风完全无关。
    }

    func testEngineExposesProtocolSurface() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = SpeechEngineFactory.make(userDefaults: defaults)
        XCTAssertFalse(engine.running)
        XCTAssertNotNil(engine.speakerRing, "协议必须暴露 task-4 取窗缓冲")
        engine.onAccentSamples = { _, _ in }
        engine.setAccentCapture(enabled: false)
        engine.setSpeakerCapture(enabled: false)
        engine.onAccentSamples = nil
    }
}
