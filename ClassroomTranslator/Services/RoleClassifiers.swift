import Foundation

/// 老师/学生二分类（全文）。
/// 优先 CoreML（包内可选）；否则关键词启发式（离线兜底，可换成 ONNX/CoreML）。
@MainActor
protocol RoleClassifying: AnyObject {
    func classify(fullText: String) -> (label: String, score: Double)?
}

/// 启发式兜底：TalkMoves 风格课堂用语。正式模型可替换本类。
@MainActor
final class HeuristicRoleClassifier: RoleClassifying {
    private let teacherCues = [
        "objective", "learning intention", "let's look", "please open",
        "today we", "we are going", "remember to", "make sure",
        "who can tell", "raise your hand", "the answer is", "for example",
        "point to", "turn to page", "clear your desk", "eyes on",
        "we're going to", "our goal", "watch me", "i'll show",
    ]
    private let studentCues = [
        "i think", "i don't know", "is it", "can you explain",
        "my answer is", "we got", "how do you", "what if",
        "i'm not sure", "wait", "oh okay", "mm hmm",
    ]

    func classify(fullText: String) -> (label: String, score: Double)? {
        let text = fullText.lowercased()
        guard text.count >= 4 else { return nil }
        var teacherHits = 0
        var studentHits = 0
        for cue in teacherCues where text.contains(cue) { teacherHits += 1 }
        for cue in studentCues where text.contains(cue) { studentHits += 1 }

        // 短问答偏向学生；讲授/指令偏向老师。
        let words = text.split(separator: " ").count
        var teacherScore = 0.45 + 0.08 * Double(teacherHits) - 0.05 * Double(studentHits)
        if words > 40 { teacherScore += 0.08 }
        if words <= 6 && teacherHits == 0 { teacherScore -= 0.12 }
        teacherScore = min(0.97, max(0.05, teacherScore))

        if teacherScore >= 0.5 {
            return ("teacher", teacherScore)
        }
        return ("student", 1.0 - teacherScore)
    }
}

/// 录音会话内的角色簿 + 分类器接线。
@MainActor
final class RoleAssignmentCoordinator {
    let book: RoleAssignmentBook
    private let classifier: any RoleClassifying

    /// 生产入口：CoreML MiniLM → 失败则启发式兜底（录音/翻译不受影响）。
    static func makeDefault() -> RoleAssignmentCoordinator {
        if let mini = RoleMiniLMClassifier() {
            StartupLog.mark("role.pipeline=minilm")
            return RoleAssignmentCoordinator(classifier: mini)
        }
        StartupLog.mark("role.pipeline=heuristic-fallback")
        return RoleAssignmentCoordinator(classifier: HeuristicRoleClassifier())
    }

    init(classifier: any RoleClassifying) {
        self.classifier = classifier
        self.book = RoleAssignmentBook()
        self.book.classify = { [classifier] text in
            classifier.classify(fullText: text)
        }
    }

    /// 某人最终句入库时调用。
    func note(utterance: String, personLabel: String?) -> RoleDecision? {
        guard let person = personLabel, !person.isEmpty else { return nil }
        return book.ingest(utterance: utterance, person: person)
    }

    /// 低置信且有新话：全文合并重判。
    func recheck() -> [String: RoleDecision] {
        book.recheckLowConfidence()
    }

    /// 会话结束：强制写入并标记置信度。
    func finalize() -> [String: RoleDecision] {
        book.finalizeAll()
    }

    /// 把决策写进别名表：角色 + 无自定义昵称时写入序号显示名（老师1/学生1）。
    /// 先写入 role，再写显示名。
    func applyToAliases(
        decisions: [String: RoleDecision],
        into map: inout [String: SpeakerAlias],
        order: [String]? = nil
    ) {
        let sequence = order ?? decisions.keys.sorted()
        let display = RoleDisplayNames.numberedDisplayNames(decisions: decisions, order: sequence)
        for (person, d) in decisions {
            var alias = map[person] ?? SpeakerAlias()
            alias.role = d.role.speakerRole
            // 先写入身份，再标记高/低置信
            alias.roleConfidence = d.confidence.rawValue
            if !alias.hasNickname, let name = display[person] {
                alias.nickname = name
            }
            map[person] = alias
        }
    }
}
