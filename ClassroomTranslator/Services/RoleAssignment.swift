import Foundation

/// 身份（老师/学生）判定策略 —— 与说话人聚类解耦。
///
/// 流程：
/// 1. 先分人（SpeakerEngine 稳定 label）；
/// 2. 用**该人全部文本**判角色（全文拼接，不只看最新一句）；
/// 3. 置信度不够 → 攒话再判，不落最终身份；
/// 4. 会话结束仍不够 → 仍写入一次，并标「低置信」；
/// 5. 低置信后若又来新话 → **全文拼接**重判并更新标记。
struct RoleAssignmentPolicy: Equatable, Sendable {
    /// 最高类概率达到此值才允许高置信定案。
    var highConfidence: Double = 0.80
    /// 定案所需最少累计字符。
    var minTextLength: Int = 12
    /// 定案所需最少句数。
    var minUtterances: Int = 2
    /// 低置信重判：距上次判定至少新增这么多字符。
    var recheckMinDelta: Int = 8

    init() {}
}

enum RoleConfidence: String, Codable, Equatable, Sendable {
    case high
    case low
}

enum AssignedRole: String, Codable, Equatable, Sendable {
    case teacher
    case student
    case other

    init(classifierLabel: String) {
        switch classifierLabel.lowercased() {
        case "teacher", "professor", "ta":
            self = .teacher
        case "student":
            self = .student
        default:
            self = .other
        }
    }

    var speakerRole: SpeakerRole {
        switch self {
        case .teacher: return .teacher
        case .student: return .student
        case .other: return .other
        }
    }
}

struct RoleDecision: Equatable, Sendable {
    var role: AssignedRole
    /// 分类器最高类概率 0...1。
    var score: Double
    /// 先写入决策，再打高/低置信标。
    var confidence: RoleConfidence
    /// 会话收束时证据不足仍写入。
    var forced: Bool
    /// 判定用的全文（拼接结果）。
    var evidenceText: String

    var isHighConfidence: Bool { confidence == .high }
}

/// 单人语料累积 + 决策状态机。
struct RoleAssignmentState: Equatable, Sendable {
    private(set) var utterances: [String] = []
    private(set) var decision: RoleDecision?
    private(set) var needsRecheck: Bool = false
    private var textLengthAtLastDecision: Int = 0

    init() {}

    var combinedText: String {
        utterances
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var utteranceCount: Int { utterances.count }
    var textLength: Int { combinedText.count }

    /// 新语句 → 是否需要跑一次分类（用全文）。
    mutating func append(_ utterance: String, policy: RoleAssignmentPolicy) -> Bool {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        utterances.append(trimmed)

        if decision == nil {
            return true
        }
        if decision?.confidence == .high {
            return false
        }
        // 低置信：又有新信息 → 全文合并重判
        let delta = textLength - textLengthAtLastDecision
        if delta >= policy.recheckMinDelta {
            needsRecheck = true
            return true
        }
        return false
    }

    func meetsEvidenceFloor(_ policy: RoleAssignmentPolicy) -> Bool {
        utteranceCount >= policy.minUtterances && textLength >= policy.minTextLength
    }

    /// 用**全文**分类结果决定是否落盘。
    mutating func consider(
        label: String,
        score: Double,
        policy: RoleAssignmentPolicy,
        forced: Bool = false
    ) -> RoleDecision? {
        let enough = meetsEvidenceFloor(policy)
        let high = score >= policy.highConfidence && enough

        if !high && !forced {
            return nil
        }

        let confidence: RoleConfidence = high ? .high : .low
        let decision = RoleDecision(
            role: AssignedRole(classifierLabel: label),
            score: score,
            confidence: confidence,
            forced: forced && !high,
            evidenceText: combinedText
        )
        // 先写入，再标记置信度
        self.decision = decision
        self.needsRecheck = false
        self.textLengthAtLastDecision = textLength
        return decision
    }

    /// 会话结束：证据不足也写入（低置信）。
    mutating func finalizeWithClassifierResult(
        label: String,
        score: Double,
        policy: RoleAssignmentPolicy
    ) -> RoleDecision? {
        if let existing = decision, existing.isHighConfidence, !needsRecheck {
            return existing
        }
        guard !utterances.isEmpty else { return nil }
        return consider(label: label, score: score, policy: policy, forced: true)
    }
}

/// 多人身份簿。key = 聚类稳定 label 或课程注册名。
@MainActor
final class RoleAssignmentBook {
    private var states: [String: RoleAssignmentState] = [:]
    var policy = RoleAssignmentPolicy()

    /// 全文 → (label, score)。生产接 MiniLM ONNX/CoreML；测试可注入。
    var classify: @MainActor (String) -> (label: String, score: Double)?

    init(classify: @escaping @MainActor (String) -> (label: String, score: Double)? = { _ in nil }) {
        self.classify = classify
    }

    func combinedText(for person: String) -> String {
        states[person]?.combinedText ?? ""
    }

    func decision(for person: String) -> RoleDecision? {
        states[person]?.decision
    }

    /// 声纹标签可能在确认第二个窗口或重聚类后回填。按当前的最终分组
    /// 重建每个人的全文，防止临时标签把不同人的话混到一起。
    func replaceTranscript(_ segments: [TranscriptSegment]) -> [String: RoleDecision] {
        let previous = states
        var rebuilt: [String: RoleAssignmentState] = [:]
        for segment in segments where segment.isFinal {
            guard let person = segment.speaker, !person.isEmpty,
                  person != SpeakerLabeler.genericSpeakerName else { continue }
            var state = rebuilt[person] ?? RoleAssignmentState()
            _ = state.append(segment.original, policy: policy)
            rebuilt[person] = state
        }
        var changed = Set<String>()
        for person in Array(rebuilt.keys) {
            guard let state = rebuilt[person] else { continue }
            if let old = previous[person], old.combinedText == state.combinedText {
                rebuilt[person] = old
            } else {
                changed.insert(person)
            }
        }
        states = rebuilt
        var decisions: [String: RoleDecision] = [:]
        for person in rebuilt.keys {
            let decision = changed.contains(person)
                ? judge(person: person, forced: false)
                : states[person]?.decision
            if let decision {
                decisions[person] = decision
            }
        }
        return decisions
    }

    /// 新语句：写入 →（需要时）用该人**全部文本**重判。
    func ingest(utterance: String, person: String) -> RoleDecision? {
        var st = states[person] ?? RoleAssignmentState()
        let shouldJudge = st.append(utterance, policy: policy)
        states[person] = st
        guard shouldJudge else { return nil }
        return judge(person: person, forced: false)
    }

    /// 对某人全文重判。
    func judge(person: String, forced: Bool) -> RoleDecision? {
        guard var st = states[person] else { return nil }
        let text = st.combinedText
        guard !text.isEmpty else { return nil }

        guard let result = classify(text) else {
            guard forced else { return nil }
            // 结束时仍无分类器结果：写入 other / 低置信
            let d = st.finalizeWithClassifierResult(label: "other", score: 0, policy: policy)
            states[person] = st
            return d
        }

        let d: RoleDecision?
        if forced {
            d = st.finalizeWithClassifierResult(label: result.label, score: result.score, policy: policy)
        } else {
            d = st.consider(label: result.label, score: result.score, policy: policy, forced: false)
        }
        states[person] = st
        return d
    }

    /// 会话结束：未定高置信的人强制写入（标低置信或保持高置信）。
    func finalizeAll() -> [String: RoleDecision] {
        var out: [String: RoleDecision] = [:]
        for person in states.keys {
            if let d = judge(person: person, forced: true) {
                out[person] = d
            }
        }
        return out
    }

    /// 低置信且有新话：全文拼接重判。
    func recheckLowConfidence() -> [String: RoleDecision] {
        var out: [String: RoleDecision] = [:]
        for (person, st) in states {
            let should = st.needsRecheck || st.decision?.confidence == .low
            guard should else { continue }
            if let d = judge(person: person, forced: false) ?? judge(person: person, forced: true) {
                out[person] = d
            }
        }
        return out
    }
}
