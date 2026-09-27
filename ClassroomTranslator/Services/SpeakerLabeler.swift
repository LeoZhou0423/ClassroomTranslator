import Foundation

/// 声纹聚类只产出稳定的人物编号。老师/学生由聚类之后的 MiniLM 判断。
struct SpeakerLabeler {
    struct Config: Equatable {
        init() {}
    }

    static var genericSpeakerName: String { String(localized: "Speaker") }

    static func numberedSpeakerName(_ rank: Int) -> String {
        String(format: String(localized: "Speaker %lld"), rank)
    }

    static func baseLabels(durations: [Double], counts: [Int], config: Config = Config()) -> [String] {
        guard durations.count == counts.count else { return [] }
        return durations.indices.map { numberedSpeakerName($0 + 1) }
    }

    /// 重聚类后优先保留旧编号，避免人物在录音中交换名字。
    static func labels(
        utteranceGroups: [Int],
        previousLabels: [String?],
        durations: [Double],
        counts: [Int],
        config: Config = Config()
    ) -> [String] {
        let base = baseLabels(durations: durations, counts: counts, config: config)
        guard previousLabels.count == utteranceGroups.count else { return base }

        var votes: [Int: [String: Int]] = [:]
        for (group, label) in zip(utteranceGroups, previousLabels) {
            guard let label, base.indices.contains(group), label != genericSpeakerName else { continue }
            votes[group, default: [:]][label, default: 0] += 1
        }

        var result = [String](repeating: "", count: base.count)
        var used = Set<String>()
        let groups = base.indices.sorted { durations[$0] > durations[$1] }
        for group in groups {
            if let old = votes[group]?
                .filter({ !used.contains($0.key) })
                .max(by: { $0.value < $1.value })?.key {
                result[group] = old
                used.insert(old)
            }
        }
        for group in base.indices where result[group].isEmpty {
            let next = (1...).lazy.map(numberedSpeakerName).first { !used.contains($0) }!
            result[group] = next
            used.insert(next)
        }
        return result
    }
}
