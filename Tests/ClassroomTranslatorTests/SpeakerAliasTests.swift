import XCTest
@testable import ClassroomTranslator

/// task-10：会话级人员映射单测 —— 昵称回退 / JSON 容错 / 四渲染点 / 隔离铁律 / 角色枚举。
final class SpeakerAliasTests: XCTestCase {
    private let map: [String: SpeakerAlias] = [
        "老师": SpeakerAlias(nickname: "王教授", role: .professor),
        "学生1": SpeakerAlias(nickname: "", role: .student)
    ]

    // MARK: - 昵称回退（resolve 与唯一出口 prefix）

    func testResolveNicknameTakesOverLabel() {
        XCTAssertEqual(SpeakerAliases.resolve("老师", in: map), "王教授")
    }

    func testResolveEmptyNicknameFallsBackToLabel() {
        XCTAssertEqual(SpeakerAliases.resolve("学生1", in: map), "学生1")
    }

    func testResolveMissingEntryFallsBackToLabel() {
        XCTAssertEqual(SpeakerAliases.resolve("旁听", in: map), "旁听")
    }

    func testResolveNilLabelIsEmpty() {
        XCTAssertEqual(SpeakerAliases.resolve(nil, in: map), "")
    }

    func testPrefixUsesNicknameAndDefaultKeepsRawLabel() {
        XCTAssertEqual(SpeakerLabels.prefix("老师", aliases: map), "王教授: ")
        // 默认参数（无映射）保持原 label —— 老调用点与既有兼容测试零变化。
        XCTAssertEqual(SpeakerLabels.prefix("老师"), "老师: ")
        XCTAssertEqual(SpeakerLabels.prefix(nil, aliases: map), "")
    }

    // MARK: - JSON 容错（缺键/坏数据/未知 role 全部不炸）

    func testDecodeNilEmptyAndGarbage() {
        XCTAssertTrue(SpeakerAliases.decode(nil).isEmpty)
        XCTAssertTrue(SpeakerAliases.decode(Data()).isEmpty)
        XCTAssertTrue(SpeakerAliases.decode(Data("not json".utf8)).isEmpty)
    }

    func testDecodeMissingKeysUseDefaults() {
        let decoded = SpeakerAliases.decode(Data(#"{"老师":{}}"#.utf8))
        XCTAssertEqual(decoded["老师"]?.nickname, "")
        XCTAssertEqual(decoded["老师"]?.role, .other)
    }

    func testDecodeUnknownRoleFallsBackToOther() {
        let decoded = SpeakerAliases.decode(Data(#"{"老师":{"nickname":"王","role":"king"}}"#.utf8))
        XCTAssertEqual(decoded["老师"]?.nickname, "王")
        XCTAssertEqual(decoded["老师"]?.role, .other)
    }

    // MARK: - 编码修剪与 roundtrip

    func testEncodeRoundtripAndPruning() {
        let encoded = SpeakerAliases.encode(map)
        XCTAssertNotNil(encoded)
        let decoded = SpeakerAliases.decode(encoded)
        XCTAssertEqual(decoded["老师"], SpeakerAlias(nickname: "王教授", role: .professor))
        XCTAssertEqual(decoded["学生1"], SpeakerAlias(nickname: "", role: .student))

        // 无昵称且角色 other → 修剪；修剪后为空 → nil（清空昵称即回退原 label 的数据面）。
        let allEmpty: [String: SpeakerAlias] = [
            "老师": .empty,
            "学生1": SpeakerAlias(nickname: "   ", role: .other)
        ]
        XCTAssertNil(SpeakerAliases.encode(allEmpty))

        // 角色可单独设置（昵称空但角色非 other 仍保留）。
        XCTAssertNotNil(
            SpeakerAliases.encode(["学生1": SpeakerAlias(nickname: "", role: .student)])
        )
    }

    // MARK: - 四渲染点

    private func makeRecord() -> TranscriptRecord {
        let record = TranscriptRecord(title: "第一讲")
        record.segments = [
            TranscriptSegment(original: "Good morning", translated: "早上好", speaker: "老师"),
            TranscriptSegment(original: "Hello", translated: "你好", speaker: "学生1")
        ]
        return record
    }

    /// 渲染点 1/4：TXT 导出（exportSingle / exportBatch 均用 bilingualTranscript）。
    func testBilingualTranscriptUsesNickname() {
        let record = makeRecord()
        record.speakerNames = SpeakerAliases.encode(map)
        let text = record.bilingualTranscript
        XCTAssertTrue(text.contains("王教授: Good morning"), "got \(text)")
        XCTAssertTrue(text.contains("学生1: Hello"), "无昵称回退原 label")
    }

    /// 渲染点 2/4：Word 导出（快照携带 aliasMap，循环走 prefix(_:aliases:)）。
    func testWordExportPrimitiveUsesNickname() {
        let record = makeRecord()
        record.speakerNames = SpeakerAliases.encode(map)
        XCTAssertEqual(SpeakerLabels.prefix("老师", aliases: record.aliasMap), "王教授: ")
    }

    /// 渲染点 3/4：会话详情（人员区与段落标签均走 resolve，编辑即时联动）。
    func testSessionDetailDisplayUsesNickname() {
        let record = makeRecord()
        record.speakerNames = SpeakerAliases.encode(map)
        XCTAssertEqual(SpeakerAliases.resolve("老师", in: record.aliasMap), "王教授")
        XCTAssertEqual(SpeakerAliases.resolve("学生1", in: record.aliasMap), "学生1")
    }

    /// 渲染点 4/4：字幕悬浮窗与实时 partial（showStableCue/renderLatestCue 走 prefix）。
    func testSubtitlePrimitiveUsesNickname() {
        let record = makeRecord()
        record.speakerNames = SpeakerAliases.encode(map)
        XCTAssertEqual(
            SpeakerLabels.prefix(record.segments[0].speaker, aliases: record.aliasMap) + "morning",
            "王教授: morning"
        )
    }

    // MARK: - 隔离铁律（用户硬约束：不能跨课程识别）

    func testRecordASettingsDoNotLeakToRecordB() {
        let recordA = makeRecord()
        let recordB = makeRecord()

        recordA.speakerNames = SpeakerAliases.encode(map)
        XCTAssertNil(recordB.speakerNames, "B 未设置 → speakerNames 仍为 nil（老数据零迁移）")
        XCTAssertTrue(recordB.bilingualTranscript.contains("老师: Good morning"))
        XCTAssertFalse(recordB.bilingualTranscript.contains("王教授"))

        // 两条记录各存各的映射，互不影响。
        recordB.speakerNames = SpeakerAliases.encode(
            ["老师": SpeakerAlias(nickname: "李老师", role: .teacher)]
        )
        XCTAssertEqual(SpeakerAliases.resolve("老师", in: recordA.aliasMap), "王教授")
        XCTAssertEqual(SpeakerAliases.resolve("老师", in: recordB.aliasMap), "李老师")
    }

    // MARK: - 角色枚举

    func testRoleEnumCasesAndRawValues() {
        XCTAssertEqual(
            SpeakerRole.allCases.map(\.rawValue),
            ["professor", "teacher", "student", "ta", "other"]
        )
        XCTAssertEqual(SpeakerRole.allCases.count, 5)
        XCTAssertEqual(SpeakerRole(rawValue: "ta"), .ta)
        XCTAssertNil(SpeakerRole(rawValue: "wizard"))
    }

    func testRoleCodableRoundtrip() throws {
        let original: [String: SpeakerAlias] = [
            "老师": SpeakerAlias(nickname: "王教授", role: .professor)
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: SpeakerAlias].self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
