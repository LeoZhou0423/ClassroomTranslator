import Foundation
import SwiftData

@Model
final class TranscriptRecord {
    var id: UUID
    var date: Date
    var title: String
    var segmentsData: Data
    var duration: TimeInterval
    var course: Course?

    var segments: [TranscriptSegment] {
        get {
            guard !segmentsData.isEmpty,
                  let decoded = try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData) else {
                return []
            }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                segmentsData = encoded
            }
        }
    }

    init(date: Date = Date(), title: String = "", segments: [TranscriptSegment] = [], duration: TimeInterval = 0) {
        self.id = UUID()
        self.date = date
        self.title = title
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
        self.duration = duration
    }

    var fullTranscript: String {
        segments.map { $0.original }.joined(separator: " ")
    }

    var fullTranslation: String {
        segments.map { $0.translated }.joined(separator: " ")
    }

    var bilingualTranscript: String {
        segments.map { segment in
            "\(segment.speakerLinePrefix)\(segment.original)\n\(segment.translated)"
        }.joined(separator: "\n\n")
    }
}

/// 说话人前缀的**唯一**格式化出口（Lead 约束）：主转写、字幕悬浮窗、
/// 会话详情、TXT/Word 导出全部经此拼 "老师: 正文"（英文冒号 + 空格），
/// 禁止在各渲染点手写字符串拼接。
enum SpeakerLabels {
    /// name 为 nil 或空 → 空前缀（老数据 / 手动模式不显示前缀）。
    static func prefix(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        return "\(name): "
    }
}

struct TranscriptSegment: Codable, Identifiable, Sendable {
    let id: UUID
    let original: String
    let translated: String
    let timestamp: Date
    let isFinal: Bool
    /// 说话人显示名（存显示语言的最终字符串，不跨语言重翻）。
    /// 旧 JSON 缺该键时 Codable 解码为 nil —— 向后兼容（见旧数据兼容单测）。
    var speaker: String?

    init(
        id: UUID = UUID(),
        original: String,
        translated: String = "",
        timestamp: Date = Date(),
        isFinal: Bool = true,
        speaker: String? = nil
    ) {
        self.id = id
        self.original = original
        self.translated = translated
        self.timestamp = timestamp
        self.isFinal = isFinal
        self.speaker = speaker
    }

    /// 统一前缀（SpeakerLabels），渲染/导出/字幕/详情页共用。
    var speakerLinePrefix: String { SpeakerLabels.prefix(speaker) }
}
