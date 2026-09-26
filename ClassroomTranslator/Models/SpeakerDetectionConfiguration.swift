import Foundation

/// 说话人识别的用户配置（task-4 设置项），默认全量开启（Lead 约定）。
/// - 说话人识别：开关，默认 true（模型缺失时整体降级为手动标注）
/// - 最多说话人数：2...4，默认 4（聚类簇数上限 K）
/// - 区分灵敏度：0.45...0.75，默认 0.60（余弦阈值 τ；越高越难合并）
struct SpeakerDetectionConfiguration: Equatable {
    static let enabledKey = "speakerDetectionEnabled"
    static let maxSpeakersKey = "speakerMaxSpeakers"
    static let thresholdKey = "speakerThreshold"
    static let defaultThreshold = 0.6

    let isEnabled: Bool
    let maximumSpeakers: Int
    let threshold: Double

    init(defaults: UserDefaults = .standard) {
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let storedMax = defaults.integer(forKey: Self.maxSpeakersKey)
        maximumSpeakers = (2...4).contains(storedMax) ? storedMax : 4
        let storedThreshold = defaults.double(forKey: Self.thresholdKey)
        threshold = (0.45...0.75).contains(storedThreshold) ? storedThreshold : Self.defaultThreshold
    }

    var clusterConfig: SpeakerClusterer.Config {
        SpeakerClusterer.Config(threshold: threshold, maximumSpeakers: maximumSpeakers)
    }

    var labelConfig: SpeakerLabeler.Config { SpeakerLabeler.Config() }
}
