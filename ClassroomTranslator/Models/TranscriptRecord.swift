import Foundation
import SwiftData

@Model
final class TranscriptRecord {
    var id: UUID
    var date: Date
    var title: String
    var segmentsData: Data
    var duration: TimeInterval
    /// task-10：本记录内人员映射 JSON（[label → {nickname, role}]，见 SpeakerAliases）。
    /// 可选字段 —— 老数据 nil = 空映射，SwiftData 轻量迁移零丢失。
    /// 隔离铁律（用户硬约束）：只属于本记录，绝不跨记录/跨课程共享。
    var speakerNames: Data?
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

    /// 本记录的人员映射（每次访问解一次 JSON —— 渲染循环里应先取一次再复用）。
    var aliasMap: [String: SpeakerAlias] {
        SpeakerAliases.decode(speakerNames)
    }

    var bilingualTranscript: String {
        let aliases = aliasMap
        return segments.map { segment in
            "\(SpeakerLabels.prefix(segment.speaker, aliases: aliases))\(segment.original)\n\(segment.translated)"
        }.joined(separator: "\n\n")
    }
}

/// 说话人前缀的**唯一**格式化出口（Lead 约束）：主转写、字幕悬浮窗、
/// 会话详情、TXT/Word 导出全部经此拼 "老师: 正文"（英文冒号 + 空格），
/// 禁止在各渲染点手写字符串拼接。
enum SpeakerLabels {
    /// name 为 nil 或空 → 空前缀（老数据 / 手动模式不显示前缀）。
    /// task-10：aliases（本记录 speakerNames 解出的映射）里该 label 有昵称时
    /// 输出 "王教授: 正文" 替代 "老师: 正文"；默认 [:] 保持原 label 行为
    /// （老调用点与兼容测试零变化）。
    static func prefix(_ name: String?, aliases: [String: SpeakerAlias] = [:]) -> String {
        guard let name, !name.isEmpty else { return "" }
        return "\(SpeakerAliases.resolve(name, in: aliases)): "
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

    /// 统一前缀（SpeakerLabels）——**原始 label**（无映射上下文的兜底路径）。
    /// 带人员映射的渲染点（TXT/Word/字幕/主转写/详情页）一律走
    /// SpeakerLabels.prefix(_:aliases:) 并传入所属记录的 aliasMap。
    var speakerLinePrefix: String { SpeakerLabels.prefix(speaker) }
}
