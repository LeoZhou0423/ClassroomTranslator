import SwiftUI

struct NewCourseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HistoryStore.self) private var historyStore
    var onCreate: (Course) -> Void

    @State private var courseName = ""
    @State private var accentCode = LanguageOptions.supportedSource(
        UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "auto"
    )
    @State private var targetLanguageCode = UserDefaults.standard.string(forKey: "translationTarget") ?? "zh-Hans"
    @State private var selectedDate = Date()
    /// task-8 排课方式：默认 single = 现行为（DatePicker 全量日期存 createdAt）。
    @State private var scheduleType: String = CourseSchedule.single
    /// 每周几（ISO 1=周一…7=周日），默认今天。
    @State private var weeklyWeekday: Int = NewCourseView.todayISOWeekday()
    /// 每月几号（clamp 1…28），默认今天的号数。
    @State private var monthlyDay: Int = min(Calendar.current.component(.day, from: Date()), 28)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text("New Course").font(.headline)
                Spacer()
                Button("Create") { createCourse() }
                    .disabled(courseName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            Form {
                Section("Course Info") {
                    TextField("Course Name (e.g. MIT 6.034)", text: $courseName)

                    // task-8：排课方式 —— 每周/每月/单次，默认单次 = 现行为。
                    Picker("Schedule Type", selection: $scheduleType) {
                        Text("Weekly").tag(CourseSchedule.weekly)
                        Text("Monthly").tag(CourseSchedule.monthly)
                        Text("Single").tag(CourseSchedule.single)
                    }
                    .pickerStyle(.segmented)

                    switch scheduleType {
                    case CourseSchedule.weekly:
                        Picker("Weekday", selection: $weeklyWeekday) {
                            ForEach(1...7, id: \.self) { isoWeekday in
                                // 符号由 Calendar 本地化（zh: 周一…周日），非 .strings。
                                Text(CourseSchedule.weekdaySymbol(isoWeekday: isoWeekday))
                                    .tag(isoWeekday)
                            }
                        }
                        DatePicker("Time", selection: $selectedDate,
                                   displayedComponents: .hourAndMinute)
                    case CourseSchedule.monthly:
                        // 29/30/31 号跨月问题 → clamp 1…28（见 Course 注释）。
                        Stepper(value: $monthlyDay, in: 1...28) {
                            HStack {
                                Text("Day of Month")
                                Spacer()
                                Text("\(monthlyDay)").foregroundColor(.secondary)
                            }
                        }
                        DatePicker("Time", selection: $selectedDate,
                                   displayedComponents: .hourAndMinute)
                    default:
                        // 单次：现有 DatePicker(.date + .hourAndMinute) 原样保留。
                        DatePicker("Date & Time", selection: $selectedDate,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section("Professor's Accent") {
                    Text("Select the accent that best matches your professor")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Accent", selection: $accentCode) {
                        ForEach(LanguageOptions.sources) { accent in
                            Text(LocalizedStringKey(accent.name)).tag(accent.code)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Translation") {
                    Picker("Target Language", selection: $targetLanguageCode) {
                        ForEach(LanguageOptions.targets) { language in
                            Text(LocalizedStringKey(language.name)).tag(language.code)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 400)
    }

    /// ISO 星期（1=周一…7=周日）：Calendar.component(.weekday) 是 1=周日…7=周六。
    private static func todayISOWeekday() -> Int {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return weekday == 1 ? 7 : weekday - 1
    }

    private func createCourse() {
        let name = courseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let course = Course(
            name: name,
            accentCode: accentCode,
            targetLanguageCode: targetLanguageCode,
            createdAt: selectedDate
        )
        // task-8：新课程显式写排课类型；各类型只填自己的字段，其余留 nil
        // （单次仍以 createdAt 为准 = 现行为；老课程 scheduleType nil 语义不变）。
        course.scheduleType = scheduleType
        switch scheduleType {
        case CourseSchedule.weekly:
            course.weeklyWeekday = weeklyWeekday
            course.scheduleHour = Calendar.current.component(.hour, from: selectedDate)
            course.scheduleMinute = Calendar.current.component(.minute, from: selectedDate)
        case CourseSchedule.monthly:
            course.monthlyDay = min(max(monthlyDay, 1), 28)
            course.scheduleHour = Calendar.current.component(.hour, from: selectedDate)
            course.scheduleMinute = Calendar.current.component(.minute, from: selectedDate)
        default:
            course.singleDate = selectedDate
        }
        historyStore.addCourse(course)
        onCreate(course)
    }
}
