import XCTest
@testable import ClassroomTranslator

/// task-4：TranscriptSegment.speaker 的旧数据兼容、统一前缀格式、
/// HistoryStore 批量回写与配置默认值。
final class SpeakerSegmentCompatibilityTests: XCTestCase {

    // MARK: - 旧 JSON 兼容（Lead 点名的回归）

    func testOldJSONWithoutSpeakerKeyDecodesToNil() throws {
        // task-4 之前的 segmentsData 没有 speaker 键 —— 必须解码成功且为 nil。
        let json = """
        [{"id":"7E1F0F2C-0000-0000-0000-000000000001","original":"Hello.","translated":"你好。","timestamp":700000000,"isFinal":true}]
        """
        let decoded = try? JSONDecoder().decode([TranscriptSegment].self, from: Data(json.utf8))
        let segments = try XCTUnwrap(decoded)
        XCTAssertEqual(segments.count, 1)
        XCTAssertNil(segments[0].speaker)
        XCTAssertEqual(segments[0].speakerLinePrefix, "")
    }

    func testRoundTripPreservesSpeaker() throws {
        let segment = TranscriptSegment(original: "Hello.", translated: "你好。", speaker: "老师")
        let data = try JSONEncoder().encode([segment])
        let decoded = try JSONDecoder().decode([TranscriptSegment].self, from: data)
        XCTAssertEqual(decoded.first?.speaker, "老师")
    }

    // MARK: - 统一前缀（Lead 约定：英文冒号 + 空格，唯一 helper）

    func testSpeakerPrefixUsesEnglishColonAndSpace() {
        XCTAssertEqual(SpeakerLabels.prefix("老师"), "老师: ")
        XCTAssertEqual(SpeakerLabels.prefix(nil), "")
        XCTAssertEqual(SpeakerLabels.prefix(""), "")
        let segment = TranscriptSegment(original: "Hi", speaker: "学生1")
        XCTAssertEqual(segment.speakerLinePrefix, "学生1: ")
    }

    func testBilingualTranscriptIncludesSpeakerPrefix() {
        let record = TranscriptRecord(title: "T", segments: [
            TranscriptSegment(original: "Hello.", translated: "你好。", speaker: "老师"),
            TranscriptSegment(original: "World.", translated: "世界。"),
        ])
        let text = record.bilingualTranscript
        XCTAssertTrue(text.contains("老师: Hello."))
        XCTAssertTrue(text.contains("\nWorld."))
        XCTAssertFalse(text.contains("World: "))
    }

    // MARK: - HistoryStore 兼容与批量回写

    @MainActor
    func testUpdateTranslationPreservesSpeaker() {
        let store = HistoryStore(isStoredInMemoryOnly: true)
        let course = Course(name: "Test")
        store.addCourse(course)
        let record = store.startNewRecord(in: course)
        let segment = TranscriptSegment(original: "Hello.", speaker: "老师")
        store.addSegmentIfNew(segment, to: record)

        store.updateTranslation(for: segment.id, to: "你好。", in: record)

        let saved = try! XCTUnwrap(record.segments.first)
        XCTAssertEqual(saved.translated, "你好。")
        XCTAssertEqual(saved.speaker, "老师", "翻译回写不得丢说话人标签")
    }

    @MainActor
    func testUpdateSpeakersBatchWritesOnlyMappedSegments() {
        let store = HistoryStore(isStoredInMemoryOnly: true)
        let course = Course(name: "Test")
        store.addCourse(course)
        let record = store.startNewRecord(in: course)
        let first = TranscriptSegment(original: "One.")
        let second = TranscriptSegment(original: "Two.")
        store.addSegmentIfNew(first, to: record)
        store.addSegmentIfNew(second, to: record)

        store.updateSpeakers([first.id: "老师", second.id: "学生1"], in: record)

        let segments = record.segments
        XCTAssertEqual(segments.first(where: { $0.id == first.id })?.speaker, "老师")
        XCTAssertEqual(segments.first(where: { $0.id == second.id })?.speaker, "学生1")

        // 空 mapping 不写库路径不炸。
        store.updateSpeakers([:], in: record)
    }

    // MARK: - 设置默认值（Lead 约定：默认全开）

    func testSpeakerDetectionDefaultsAndStoredValues() {
        let suite = "SpeakerDetectionConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = SpeakerDetectionConfiguration(defaults: defaults)
        XCTAssertTrue(fresh.isEnabled, "说话人识别默认开启")
        XCTAssertEqual(fresh.maximumSpeakers, 4)
        XCTAssertEqual(fresh.threshold, 0.6, accuracy: 0.0001)

        defaults.set(false, forKey: SpeakerDetectionConfiguration.enabledKey)
        defaults.set(2, forKey: SpeakerDetectionConfiguration.maxSpeakersKey)
        defaults.set(0.75, forKey: SpeakerDetectionConfiguration.thresholdKey)
        let stored = SpeakerDetectionConfiguration(defaults: defaults)
        XCTAssertFalse(stored.isEnabled)
        XCTAssertEqual(stored.maximumSpeakers, 2)
        XCTAssertEqual(stored.threshold, 0.75, accuracy: 0.0001)

        // 越界 / 脏值 → 回落默认。
        defaults.set(99, forKey: SpeakerDetectionConfiguration.maxSpeakersKey)
        defaults.set(0.0, forKey: SpeakerDetectionConfiguration.thresholdKey)
        let clamped = SpeakerDetectionConfiguration(defaults: defaults)
        XCTAssertEqual(clamped.maximumSpeakers, 4)
        XCTAssertEqual(clamped.threshold, 0.6, accuracy: 0.0001)
    }

    func testClusterConfigClampsThresholdAndSpeakerCount() {
        let config = SpeakerClusterer.Config(threshold: 5.0, maximumSpeakers: 99)
        XCTAssertEqual(config.threshold, 0.75)
        XCTAssertEqual(config.maximumSpeakers, 4)
        let low = SpeakerClusterer.Config(threshold: 0.1, maximumSpeakers: 1)
        XCTAssertEqual(low.threshold, 0.45)
        XCTAssertEqual(low.maximumSpeakers, 2)
    }

    // MARK: - 引擎在模型缺失时惰性（降级为手动标注）

    @MainActor
    func testEngineWithoutModelIsInert() {
        let ring = SpeakerAudioRing(capacitySeconds: 1)
        let engine = SpeakerEngine(ring: ring, model: nil)
        XCTAssertFalse(engine.canInfer)
        engine.activate(recordID: UUID())
        XCTAssertFalse(engine.canInfer, "模型缺失 → 引擎不得推理")
        engine.segmentsCommitted([UUID()])
        XCTAssertNil(engine.currentLabel, "无模型时段落保持无标签（手动标注）")
        engine.shutdown()
    }
}
