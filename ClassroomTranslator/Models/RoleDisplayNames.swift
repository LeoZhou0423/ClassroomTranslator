import Foundation

/// 角色显示名：多老师/多学生只加序号（老师1、老师2、学生1…）。
/// 写入 SpeakerAlias.nickname（无自定义昵称时），使转写前缀 / 详情 / 导出一致显示。
enum RoleDisplayNames {
    static func teacherName(_ index: Int) -> String {
        String(format: String(localized: "Teacher %lld"), index)
    }

    static func studentName(_ index: Int) -> String {
        String(format: String(localized: "Student %lld"), index)
    }

    static func otherName(_ index: Int) -> String {
        String(format: String(localized: "Speaker %lld"), index)
    }

    /// 按首次出现顺序给同角色加 1/2/3…。
    /// 单人角色仍用「老师」「学生」（不带 1），多人时才编号。
    static func numberedDisplayNames(
        decisions: [String: RoleDecision],
        order: [String]
    ) -> [String: String] {
        var teachers: [String] = []
        var students: [String] = []
        var others: [String] = []
        for person in order {
            guard let d = decisions[person] else { continue }
            switch d.role {
            case .teacher: teachers.append(person)
            case .student: students.append(person)
            case .other: others.append(person)
            }
        }
        var out: [String: String] = [:]
        let multiTeacher = teachers.count > 1
        let multiStudent = students.count > 1
        let multiOther = others.count > 1

        for (i, person) in teachers.enumerated() {
            out[person] = multiTeacher ? teacherName(i + 1) : String(localized: "Teacher")
        }
        for (i, person) in students.enumerated() {
            out[person] = multiStudent ? studentName(i + 1) : String(localized: "Student")
        }
        for (i, person) in others.enumerated() {
            out[person] = multiOther ? otherName(i + 1) : String(localized: "Speaker")
        }
        return out
    }
}
