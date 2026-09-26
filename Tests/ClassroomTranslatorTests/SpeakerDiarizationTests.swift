import XCTest
@testable import ClassroomTranslator

/// task-4：说话人取窗 / 在线聚类 / 命名规则的纯逻辑回归。
final class SpeakerDiarizationTests: XCTestCase {

    // MARK: - 取窗策略

    func testWindowPolicyInheritsShortSpan() {
        // 上一窗口到当前末端不足 0.6s：不开窗，段落继承当前标签。
        let decision = SpeakerWindowPolicy.decision(
            spanStart: 0,
            spanEnd: SpeakerWindowPolicy.minimumWindowSamples + SpeakerWindowPolicy.tailLagSamples - 1,
            availableStart: 0
        )
        XCTAssertEqual(decision, .inherit)
    }

    func testWindowPolicyNormalSpanEndsBeforeTailLag() {
        // 2.2s 跨度 → 窗口 = [0, 2.0s]（末端去掉 0.2s 尾迟滞）。
        let decision = SpeakerWindowPolicy.decision(
            spanStart: 0,
            spanEnd: 35_200,
            availableStart: 0
        )
        XCTAssertEqual(decision, .window(start: 0, end: 32_000))
    }

    func testWindowPolicyLongSpanTakesTailWindow() {
        // 跨度 10s：只取紧贴句尾的 4s 尾窗（刚说完的语音在尾部）。
        let decision = SpeakerWindowPolicy.decision(
            spanStart: 0,
            spanEnd: 160_000,
            availableStart: 0
        )
        guard case let .window(start, end) = decision else {
            return XCTFail("expected window, got \(decision)")
        }
        XCTAssertEqual(end - start, SpeakerWindowPolicy.maximumWindowSamples)
        XCTAssertEqual(end, 160_000 - SpeakerWindowPolicy.tailLagSamples)
    }

    func testWindowPolicyEvictedDataInherits() {
        // 老数据已被逐出（availableStart 越过 spanStart 且可用不足）→ 继承。
        let decision = SpeakerWindowPolicy.decision(
            spanStart: 0,
            spanEnd: 100_000,
            availableStart: 99_000
        )
        XCTAssertEqual(decision, .inherit)
    }

    func testSilenceGateByRMS() {
        XCTAssertEqual(SpeakerWindowPolicy.rms([Float](repeating: 0, count: 1600)), 0)
        XCTAssertLessThan(SpeakerWindowPolicy.rms([Float](repeating: 0, count: 1600)), SpeakerWindowPolicy.silenceRMS)
        XCTAssertGreaterThanOrEqual(SpeakerWindowPolicy.rms([Float](repeating: 0.2, count: 1600)), SpeakerWindowPolicy.silenceRMS)
    }

    // MARK: - 在线 leader-follower 聚类

    func testClustererMergesSameSpeakerAboveThreshold() {
        var clusterer = SpeakerClusterer(config: .init(threshold: 0.6, maximumSpeakers: 4))
        let first: [Float] = [1, 0, 0]
        let similar: [Float] = [0.98, 0.2, 0]
        let group0 = clusterer.assign(first)
        let group1 = clusterer.assign(similar)
        XCTAssertEqual(group0, 0)
        XCTAssertEqual(group1, 0)
        XCTAssertEqual(clusterer.centroids.count, 1)
    }

    func testClustererStartsNewGroupBelowThreshold() {
        var clusterer = SpeakerClusterer(config: .init(threshold: 0.6, maximumSpeakers: 4))
        XCTAssertEqual(clusterer.assign([1, 0, 0]), 0)
        XCTAssertEqual(clusterer.assign([0, 1, 0]), 1)
        XCTAssertEqual(clusterer.centroids.count, 2)
    }

    func testClustererCapsAtMaxSpeakers() {
        // K = 2：第三个不同声音不再开新簇，归入最相似的既有簇。
        var clusterer = SpeakerClusterer(config: .init(threshold: 0.6, maximumSpeakers: 2))
        XCTAssertEqual(clusterer.assign([1, 0, 0]), 0)
        XCTAssertEqual(clusterer.assign([0, 1, 0]), 1)
        let third = clusterer.assign([0, 0, 1])
        XCTAssertEqual(third, 0)
        XCTAssertEqual(clusterer.centroids.count, 2)
    }

    func testClustererEmaKeepsGraduallyDriftingSpeakerInOneGroup() {
        // 每步转 15° 的连续漂移：5 步累计 75°（对初始质心余弦 0.26 < τ），
        // 没有 EMA 质心更新会裂开；有 EMA 应始终并入组 0。
        var clusterer = SpeakerClusterer(config: .init(threshold: 0.6, maximumSpeakers: 4, emaAlpha: 0.3))
        for step in 0..<6 {
            let angle = Double(step) * 15.0 * Double.pi / 180.0
            let embedding = [Float](arrayLiteral: Float(cos(angle)), Float(sin(angle)), 0)
            XCTAssertEqual(clusterer.assign(embedding), 0, "drift step \(step) should stay in group 0")
        }
        XCTAssertEqual(clusterer.centroids.count, 1)
    }

    func testClustererNilOnEmptyEmbedding() {
        var clusterer = SpeakerClusterer()
        XCTAssertNil(clusterer.assign([]))
    }

    // MARK: - 全量重聚类

    func testReclusterKeepsIdenticalPairsTogether() {
        let a1: [Float] = [1, 0, 0]
        let a2: [Float] = [1, 0, 0]
        let b1: [Float] = [0, 1, 0]
        let b2: [Float] = [0, 1, 0]
        let c1: [Float] = [0, 0, 1]
        let c2: [Float] = [0, 0, 1]
        let groups = SpeakerClusterer.recluster(
            [a1, a2, b1, b2, c1, c2],
            config: .init(threshold: 0.6, maximumSpeakers: 4)
        )
        XCTAssertEqual(groups.count, 6)
        XCTAssertEqual(groups[0], groups[1])
        XCTAssertEqual(groups[2], groups[3])
        XCTAssertEqual(groups[4], groups[5])
        XCTAssertNotEqual(groups[0], groups[2])
        XCTAssertNotEqual(groups[2], groups[4])
    }

    func testReclusterCapsAtMaxSpeakersByForcedMerge() {
        // 3 个天然不同的簇、K=2 → 必须强制合并到 2 组。
        let groups = SpeakerClusterer.recluster(
            [[1, 0, 0], [1, 0, 0], [0, 1, 0], [0, 1, 0], [0, 0, 1], [0, 0, 1]],
            config: .init(threshold: 0.6, maximumSpeakers: 2)
        )
        XCTAssertEqual(Set(groups).count, 2)
    }

    func testClustererRebuildMatchesNewGroups() {
        var clusterer = SpeakerClusterer(config: .init(threshold: 0.6, maximumSpeakers: 4))
        let embeddings: [[Float]] = [[1, 0, 0], [1, 0, 0], [0, 1, 0]]
        let groups = SpeakerClusterer.recluster(embeddings, config: clusterer.config)
        clusterer.rebuild(embeddings: embeddings, groups: groups)
        XCTAssertEqual(clusterer.centroids.count, Set(groups).count)
        // 重建后在线 assign 应把同组嵌入还给同一个簇。
        XCTAssertEqual(clusterer.assign([1, 0, 0]), groups[0])
        XCTAssertEqual(clusterer.assign([0, 1, 0]), groups[2])
    }

    // MARK: - 命名规则（§4.4 / §4.6.3）

    func testSingleShortClusterUsesGenericSpeakerName() {
        // 单簇总时长 <30s：不硬猜老师。
        let labels = SpeakerLabeler.baseLabels(durations: [10], counts: [3])
        XCTAssertEqual(labels, [SpeakerLabeler.genericSpeakerName])
    }

    func testSingleQualifiedClusterBecomesTeacher() {
        // 单簇 ≥2 句、≥6s、总时长 ≥30s → 老师。
        let labels = SpeakerLabeler.baseLabels(durations: [40], counts: [6])
        XCTAssertEqual(labels, [SpeakerLabeler.teacherName])
    }

    func testLongestQualifyingClusterIsTeacherOthersAreStudents() {
        // 老师竞争：≥2 句且 ≥6s；其余按时长降序编号学生。
        let labels = SpeakerLabeler.baseLabels(durations: [12, 4, 2], counts: [5, 3, 1])
        XCTAssertEqual(labels[0], SpeakerLabeler.teacherName)
        XCTAssertEqual(labels[1], SpeakerLabeler.studentName(1))
        XCTAssertEqual(labels[2], SpeakerLabeler.studentName(2))
    }

    func testNoTeacherCandidateMeansNumberedSpeakers() {
        // 都不满足老师条件（句数不足 / 时长不足）→ 说话人1/2，不硬猜。
        let labels = SpeakerLabeler.baseLabels(durations: [5, 4], counts: [1, 1])
        XCTAssertEqual(labels[0], SpeakerLabeler.numberedSpeakerName(1))
        XCTAssertEqual(labels[1], SpeakerLabeler.numberedSpeakerName(2))
    }

    func testTeacherHysteresisKeepsPreviousTeacherWhenMarginSmall() {
        // base 老师是簇1（6.0s），但旧老师票都在簇0（5.5s），时长差 0.5 < 2s → 不翻转。
        let durations = [5.5, 6.0]
        let counts = [3, 3]
        let utteranceGroups = [0, 0, 1, 1]
        let previous: [String?] = [
            SpeakerLabeler.teacherName, SpeakerLabeler.teacherName,
            SpeakerLabeler.studentName(1), SpeakerLabeler.studentName(1),
        ]
        let labels = SpeakerLabeler.labels(
            utteranceGroups: utteranceGroups,
            previousLabels: previous,
            durations: durations,
            counts: counts
        )
        XCTAssertEqual(labels[0], SpeakerLabeler.teacherName)
        XCTAssertNotEqual(labels[1], SpeakerLabeler.teacherName)
    }

    func testStudentNumberingStableAcrossDurationRankFlip() {
        // 时长排名翻转时，投票优先保住原名（说话人1 不随排名漂移）。
        let utteranceGroups = [0, 0, 1, 1]
        let previous: [String?] = [
            SpeakerLabeler.numberedSpeakerName(1), SpeakerLabeler.numberedSpeakerName(1),
            SpeakerLabeler.numberedSpeakerName(2), SpeakerLabeler.numberedSpeakerName(2),
        ]
        let labels = SpeakerLabeler.labels(
            utteranceGroups: utteranceGroups,
            previousLabels: previous,
            durations: [2, 5],   // 现在簇1 更长，base 会把说话人1 给簇1
            counts: [2, 2]
        )
        XCTAssertEqual(labels[0], SpeakerLabeler.numberedSpeakerName(1))
        XCTAssertEqual(labels[1], SpeakerLabeler.numberedSpeakerName(2))
    }

    func testFirstResolutionWithoutHistoryUsesBaseLabels() {
        let labels = SpeakerLabeler.labels(
            utteranceGroups: [0, 1],
            previousLabels: [nil, nil],
            durations: [12, 3],
            counts: [4, 1]
        )
        XCTAssertEqual(labels, SpeakerLabeler.baseLabels(durations: [12, 3], counts: [4, 1]))
    }
}
