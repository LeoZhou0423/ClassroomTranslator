import Foundation

/// task-10：会话级人员映射（昵称/角色）—— 数据结构与纯逻辑。
///
/// 隔离铁律（用户原话「不能跨课程识别这个教授，这是不可取的」）：
/// 只随 TranscriptRecord.speakerNames 存在本条记录内 —— 不建全局说话人库、
/// 不跨记录/跨课程存 embedding 或匹配；清空昵称即回退显示原 label。
/// 老数据 speakerNames nil → 空映射，零迁移零行为变化。

/// 角色枚举：rawValue 进 JSON（稳定可演进 —— 未知值解码为 .other，不炸老/新数据）。
enum SpeakerRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case professor
    case teacher
    case student
    case ta
    case other

    var id: String { rawValue }

    /// Picker 展示键（view 侧包 LocalizedStringKey 查 .strings；en 无表回落 key 原文）。
    var title: String {
        switch self {
        case .professor: return "Professor"
        case .teacher: return "Teacher"
        case .student: return "Student"
        case .ta: return "Teaching Assistant"
        case .other: return "Other"
        }
    }
}

/// 一条标签的昵称 + 角色。Codable 容错：缺键/未知 role 不抛错。
struct SpeakerAlias: Codable, Equatable, Sendable {
    var nickname: String
    var role: SpeakerRole

    static let empty = SpeakerAlias()

    init(nickname: String = "", role: SpeakerRole = .other) {
        self.nickname = nickname
        self.role = role
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        role = (try? container.decodeIfPresent(String.self, forKey: .role))
            .flatMap { $0 }
            .flatMap(SpeakerRole.init(rawValue:)) ?? .other
    }

    /// 昵称 trim 后非空才算有昵称（显示层回退判断用）。
    var hasNickname: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 映射的编解码与显示名解析（SpeakerLabels 唯一出口与详情页共用）。
enum SpeakerAliases {
    /// Data? → map。nil / 空 / 坏 JSON / 缺键 / 未知 role 一律不炸 → [:] 或默认值。
    static func decode(_ data: Data?) -> [String: SpeakerAlias] {
        guard let data, !data.isEmpty else { return [:] }
        return (try? JSONDecoder().decode([String: SpeakerAlias].self, from: data)) ?? [:]
    }

    /// map → Data（sortedKeys 稳定序列化）。修剪「无昵称且角色为 other」的
    /// 无意义条目；修剪后为空 → nil（不写无意义 JSON）。
    static func encode(_ map: [String: SpeakerAlias]) -> Data? {
        let pruned = map.filter { $0.value.hasNickname || $0.value.role != .other }
        guard !pruned.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(pruned)
    }

    /// 显示名：昵称非空 → 昵称；否则回退原 label。nil label → ""。
    static func resolve(_ label: String?, in map: [String: SpeakerAlias]) -> String {
        guard let label else { return "" }
        if let alias = map[label], alias.hasNickname {
            return alias.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return label
    }
}
