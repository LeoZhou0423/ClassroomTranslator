import XCTest
@testable import ClassroomTranslator

/// task-6 Step 1：引擎选择的纯逻辑（key/默认值/可用性回退/工厂实例化）。
/// 验收重点：任何已存值在 Step 1 都解析为 Apple —— 默认行为零变化。
final class SpeechEngineSelectionTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SpeechEngineSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
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

    func testStoredSherpaResolvesToAppleUntilStep2() {
        // sherpa 值已存但实现未落地 → raw 解析为 .sherpa，resolved 回退 apple。
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("sherpa", forKey: SpeechEngineKind.defaultsKey)
        let kind = SpeechEngineKind(userDefaults: defaults)
        XCTAssertEqual(kind, .sherpa)
        XCTAssertFalse(kind.isAvailable, "Step 1：sherpa 实现未落地")
        XCTAssertEqual(kind.resolved, .apple)
    }

    func testUnknownValueFallsBackToApple() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("gpt4-realtime", forKey: SpeechEngineKind.defaultsKey)
        XCTAssertEqual(SpeechEngineKind(userDefaults: defaults), .apple)
    }

    func testFactoryAlwaysReturnsAppleEngineInStep1() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in ["", "apple", "sherpa", "garbage"] {
            defaults.set(value, forKey: SpeechEngineKind.defaultsKey)
            let engine = SpeechEngineFactory.make(userDefaults: defaults)
            XCTAssertTrue(
                engine is AppleSpeechEngine,
                "stored=\(value) 应在 Step 1 恒返回 AppleSpeechEngine"
            )
        }
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
