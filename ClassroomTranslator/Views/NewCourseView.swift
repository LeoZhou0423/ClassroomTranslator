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

    private func createCourse() {
        let name = courseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let course = Course(
            name: name,
            accentCode: accentCode,
            targetLanguageCode: targetLanguageCode,
            createdAt: selectedDate
        )
        historyStore.addCourse(course)
        onCreate(course)
    }
}
