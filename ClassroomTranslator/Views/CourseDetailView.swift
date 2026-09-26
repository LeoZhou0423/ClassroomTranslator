import SwiftUI

struct CourseDetailView: View {
    @Environment(HistoryStore.self) private var historyStore
    let course: Course
    var onDelete: (() -> Void)?

    @State private var showRecording = false
    @State private var showDeleteConfirm = false
    @State private var showCourseSettings = false
    @State private var recordingTranslationManager = TranslationManager()
    @State private var selectedRecord: TranscriptRecord?
    @State private var recordToDelete: TranscriptRecord?
    @State private var searchText = ""
    @State private var exportFeedback = ""

    var body: some View {
        Group {
            if showRecording {
                StableRecordingView(course: course, historyStore: historyStore, translationManager: recordingTranslationManager) {
                    showRecording = false
                }
                .modifier(TranslationSessionCompat(
                    manager: recordingTranslationManager,
                    sourceLanguage: course.accentCode,
                    targetLanguage: course.effectiveTargetLanguageCode
                ))
            } else {
                courseOverview
                    // task-12 排查产出（run 36241937270）：同一视图叠两个 .sheet 只有
                    // 后声明的生效（macOS 经典坑）—— 外层课程设置 sheet 把会话 sheet
                    // 盖死：行点击写入 selectedRecord 也从不呈现（CI 四连点击、sheets
                    // 恒 0 实证）。会话 sheet 挪进内层视图分层，两个 sheet 各占一层。
                    .sheet(item: $selectedRecord) { SessionDetailView(record: $0) }
            }
        }
        .sheet(isPresented: $showCourseSettings) {
            CourseSettingsEditor(course: course).environment(historyStore)
        }
        .confirmationDialog("Delete Recording", isPresented: Binding(
            get: { recordToDelete != nil },
            set: { if !$0 { recordToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let recordToDelete { historyStore.deleteRecord(recordToDelete) }
                recordToDelete = nil
            }
            Button("Cancel", role: .cancel) { recordToDelete = nil }
        } message: { Text("This recording and its transcript will be permanently deleted.") }
        .alert("Export", isPresented: Binding(
            get: { !exportFeedback.isEmpty },
            set: { if !$0 { exportFeedback = "" } }
        )) {
            Button("OK") { exportFeedback = "" }
        } message: { Text(exportFeedback) }
        .confirmationDialog("Delete Course", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                historyStore.deleteCourse(course)
                onDelete?()
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Are you sure you want to delete this course? All recordings will be removed.") }
    }

    private var courseOverview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(course.name).font(.title2).bold()
                    // task-8：排课描述（课程列表与详情都显示）。
                    Text(course.scheduleDescription)
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        Label(course.accentName, systemImage: "waveform")
                        Label(course.targetLanguageName, systemImage: "character.bubble")
                    }
                    .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button { showCourseSettings = true } label: { Label("Course Settings", systemImage: "slider.horizontal.3") }
                Button { showRecording = true } label: { Label("New Recording", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent)
            }.padding()
            Divider()

            if filteredRecords.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No recordings yet" : "No Matching Recordings",
                    systemImage: searchText.isEmpty ? "mic.circle" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "Start a recording to create the first transcript." : "Try a different search term.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredRecords) { record in
                    HStack(spacing: 12) {
                        Button { selectedRecord = record } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                // task-9：标题空/仅空白 → 「M月d日」占位（SessionDisplay 纯函数）。
                                Text(SessionDisplay.titleText(title: record.title, date: record.date))
                                    .font(.headline)
                                // 日期 + 时长（复用 ExportManager.formatDuration，已有单测覆盖）。
                                HStack(spacing: 8) {
                                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                    Text(ExportManager.formatDuration(record.duration))
                                }
                                .font(.caption).foregroundColor(.secondary)
                                Text(record.fullTranscript).font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Menu {
                            Button("View or Edit") { selectedRecord = record }
                            Button("Export Word") { exportWord(record) }
                            Button("Export Text") { exportText(record) }
                            Divider()
                            Button("Delete", role: .destructive) { recordToDelete = record }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }.padding(.vertical, 4)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search recordings")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) { showDeleteConfirm = true } label: { Image(systemName: "trash") }
                    // VIS-10：图标按钮没有文字，VoiceOver 读不出用途。
                    .accessibilityLabel(Text("Delete Course"))
            }
        }
    }

    private var filteredRecords: [TranscriptRecord] {
        let records = historyStore.recordsForCourse(course).sorted { $0.date > $1.date }
        guard !searchText.isEmpty else { return records }
        // 同 HistoryView：一次过滤只解一次 JSON。
        return records.filter { record in
            if record.title.localizedCaseInsensitiveContains(searchText) { return true }
            let segments = record.segments
            let transcript = segments.map { $0.original }.joined(separator: " ")
            let translation = segments.map { $0.translated }.joined(separator: " ")
            return transcript.localizedCaseInsensitiveContains(searchText)
                || translation.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func exportWord(_ record: TranscriptRecord) {
        ExportManager.exportWord(record: record) { exportFeedback = exportMessage(for: $0) }
    }

    private func exportText(_ record: TranscriptRecord) {
        ExportManager.exportSingle(record: record) { exportFeedback = exportMessage(for: $0) }
    }

    private func exportMessage(for result: Result<URL, Error>) -> String {
        switch result {
        case .success(let url): return String(localized: "Exported successfully: \(url.lastPathComponent)")
        case .failure(let error):
            // UX-07：取消返回空串，alert 绑定非空才触发，因此完全静默。
            return ExportManager.isCancellation(error) ? "" : error.localizedDescription
        }
    }
}

private struct CourseSettingsEditor: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    let course: Course
    @State private var name: String
    @State private var source: String
    @State private var target: String

    init(course: Course) {
        self.course = course
        _name = State(initialValue: course.name)
        _source = State(initialValue: course.accentCode)
        _target = State(initialValue: course.effectiveTargetLanguageCode)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text("Course Settings").font(.headline)
                Spacer()
                Button("Save", action: save).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
            Divider()
            Form {
                TextField("Course Name", text: $name)
                Picker("Teacher Language / Model", selection: $source) {
                    ForEach(LanguageOptions.sources) { Text(LocalizedStringKey($0.name)).tag($0.code) }
                }
                Picker("Target Language", selection: $target) {
                    ForEach(LanguageOptions.targets) { Text(LocalizedStringKey($0.name)).tag($0.code) }
                }
            }.formStyle(.grouped)
        }.frame(width: 480, height: 360)
    }

    private func save() {
        course.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        course.accentCode = source
        course.targetLanguageCode = target
        historyStore.save()
        dismiss()
    }
}
