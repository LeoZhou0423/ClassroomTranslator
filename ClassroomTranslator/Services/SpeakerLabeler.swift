import Foundation

/// 簇 → 显示名（报告 §4.4 / §4.6.3，纯逻辑可单测）。
/// 命名规则（Lead 已确认）：
///  · 单簇且总时长 <30s：不硬猜老师 → 通用名"说话人"；
///  · 单簇达标（≥2 句且 ≥6s 且总时长 ≥30s）→ "老师"；
///  · 多簇：满足"≥2 句且 ≥6s"的簇里时长最长者为"老师"，其余按
///    时长降序编号"学生1/学生2…"；无人满足老师条件 → 全部"说话人1/2…"；
///  · 重聚类后用旧标签投票做滞后（hysteresis）：新旧老师时长差 <2s
///    且旧老师票数占优时不翻转，学生编号同样优先保留原名。
/// 显示名是**最终字符串**（String(localized:) 取当前语言），存进
/// TranscriptSegment.speaker 后不跨语言重翻。
struct SpeakerLabeler {
    struct Config: Equatable {
        var teacherMinSegments = 2
        var teacherMinSeconds: Double = 6
        var singleClusterTeacherSeconds: Double = 30
        var teacherSwapMarginSeconds: Double = 2

        init(
            teacherMinSegments: Int = 2,
            teacherMinSeconds: Double = 6,
            singleClusterTeacherSeconds: Double = 30,
            teacherSwapMarginSeconds: Double = 2
        ) {
            self.teacherMinSegments = teacherMinSegments
            self.teacherMinSeconds = teacherMinSeconds
            self.singleClusterTeacherSeconds = singleClusterTeacherSeconds
            self.teacherSwapMarginSeconds = teacherSwapMarginSeconds
        }
    }

    static var teacherName: String { String(localized: "Teacher") }
    static var genericSpeakerName: String { String(localized: "Speaker") }

    static func studentName(_ rank: Int) -> String {
        String(format: String(localized: "Student %lld"), rank)
    }

    static func numberedSpeakerName(_ rank: Int) -> String {
        String(format: String(localized: "Speaker %lld"), rank)
    }

    /// 基础命名（无历史时直接用；也是投票逻辑的回退基线）。
    static func baseLabels(durations: [Double], counts: [Int], config: Config = Config()) -> [String] {
        let groups = durations.count
        guard groups > 0, counts.count == groups else { return [] }
        let total = durations.reduce(0, +)

        if groups == 1 {
            let qualifies = counts[0] >= config.teacherMinSegments
                && durations[0] >= config.teacherMinSeconds
                && total >= config.singleClusterTeacherSeconds
            return [qualifies ? teacherName : genericSpeakerName]
        }

        // 老师竞争：≥2 句且 ≥6s，时长最长者当选。
        var teacherIndex = -1
        var bestDuration = -Double.greatestFiniteMagnitude
        for index in 0..<groups
        where counts[index] >= config.teacherMinSegments && durations[index] >= config.teacherMinSeconds {
            if durations[index] > bestDuration {
                bestDuration = durations[index]
                teacherIndex = index
            }
        }

        // 其余按时长降序编号（同长按簇下标保序）。
        let others = (0..<groups).filter { $0 != teacherIndex }
            .sorted {
                if durations[$0] != durations[$1] { return durations[$0] > durations[$1] }
                return $0 < $1
            }

        var labels = [String](repeating: "", count: groups)
        if teacherIndex >= 0 {
            labels[teacherIndex] = teacherName
            for (rank, index) in others.enumerated() {
                labels[index] = studentName(rank + 1)
            }
        } else {
            for (rank, index) in others.enumerated() {
                labels[index] = numberedSpeakerName(rank + 1)
            }
        }
        return labels
    }

    /// 重聚类/在线更新后的命名：baseLabels + 旧标签投票稳定化。
    /// - Parameters:
    ///   - utteranceGroups: 每条语句的（新）簇下标
    ///   - previousLabels: 每条语句的旧显示名（nil = 新语句）
    ///   - durations/counts: 新分组的统计
    /// - Returns: 每个簇的显示名（长度 = 簇数）
    static func labels(
        utteranceGroups: [Int],
        previousLabels: [String?],
        durations: [Double],
        counts: [Int],
        config: Config = Config()
    ) -> [String] {
        let groups = durations.count
        guard groups > 0 else { return [] }
        var base = baseLabels(durations: durations, counts: counts, config: config)
        guard previousLabels.count == utteranceGroups.count, !previousLabels.isEmpty else {
            return base
        }

        // 票数：cluster → label → 次数。
        var votes: [Int: [String: Int]] = [:]
        var teacherVotes: [Int: Int] = [:]
        var teacherTotal = 0
        for (group, label) in zip(utteranceGroups, previousLabels) {
            guard let label, group >= 0, group < groups else { continue }
            votes[group, default: [:]][label, default: 0] += 1
            if label == teacherName {
                teacherVotes[group, default: 0] += 1
                teacherTotal += 1
            }
        }

        // 老师滞后：base 老师与"旧老师票仓"时长差 < margin 且旧票占优 → 不翻转。
        if let baseTeacher = base.firstIndex(of: teacherName), teacherTotal > 0 {
            let oldTeacherStronghold = teacherVotes.filter { $0.key != baseTeacher }
                .max(by: { $0.value < $1.value })
            if let stronghold = oldTeacherStronghold,
               teacherVotes[stronghold.key, default: 0] > teacherVotes[baseTeacher, default: 0],
               durations[baseTeacher] - durations[stronghold.key] < config.teacherSwapMarginSeconds {
                // 交换：旧老师簇拿到"老师"，原 base 老师接它的标签。
                let displaced = base[stronghold.key]
                base[stronghold.key] = teacherName
                base[baseTeacher] = displaced
            }
        }

        // 学生/编号稳定化：簇内旧票最多的可用标签优先，其次 base。
        var used = Set<String>()
        var seen = Set<String>()
        let available = base.filter { !$0.isEmpty && seen.insert($0).inserted }

        var result = [String](repeating: "", count: groups)
        let order = (0..<groups).sorted {
            if durations[$0] != durations[$1] { return durations[$0] > durations[$1] }
            return $0 < $1
        }
        for group in order {
            let preferred = votes[group]?
                .filter { !used.contains($0.key) && available.contains($0.key) }
                .max(by: { $0.value < $1.value })?.key
            if let preferred {
                result[group] = preferred
                used.insert(preferred)
            } else {
                let fallback = base[group]
                if !fallback.isEmpty, !used.contains(fallback) {
                    result[group] = fallback
                    used.insert(fallback)
                }
            }
        }
        // 兜底：任何仍未命名的簇（理论上不发生）用 base。
        for group in 0..<groups where result[group].isEmpty {
            result[group] = base[group]
        }
        return result
    }
}
