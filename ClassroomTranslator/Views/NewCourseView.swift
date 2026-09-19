import SwiftUI

struct NewCourseView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(HistoryStore.self) private var historyStore
    var onCreate: (Course) -> Void

    @State private var courseName = ""
    @State private var accentCode = "en-US"
    @State private var selectedDate = Date()

    private let accents: [(name: String, code: String)] = [
        ("American", "en-US"),
        ("British", "en-GB"),
        ("Australian", "en-AU"),
        ("New Zealand", "en-NZ"),
        ("Irish", "en-IE"),
        ("South African", "en-ZA"),
        ("Canadian", "en-CA"),
        ("Indian", "en-IN"),
        ("Chinese", "zh-Hans"),
        ("Japanese", "ja-JP"),
        ("Korean", "ko-KR"),
    ]

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

                    DatePicker("Date & Time", selection: $selectedDate,
                               displayedComponents: [.date, .hourAndMinute])
                }

                Section("Professor's Accent") {
                    Text("Select the accent that best matches your professor")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Accent", selection: $accentCode) {
                        ForEach(accents, id: \.code) { accent in
                            Text(accent.name).tag(accent.code)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, minHeight: 400)
    }

    private func createCourse() {
        let name = courseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let course = Course(name: name, accentCode: accentCode, createdAt: selectedDate)
        historyStore.addCourse(course)
        onCreate(course)
    }
}
