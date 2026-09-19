import SwiftUI

@MainActor
struct SessionDetailView: View {
    private struct DraftSegment: Identifiable {
        let id: UUID
        var original: String
        var translated: String
        let timestamp: Date
        let isFinal: Bool
    }

    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    let record: TranscriptRecord
    @State private var isEditing = false
    @State private var title: String
    @State private var drafts: [DraftSegment]
    @State private var feedback = ""
    @State private var translationManager = TranslationManager()
    @State private var isFillingTranslations = false

    init(record: TranscriptRecord) {
        self.record = record
        _title = State(initialValue: record.title)
        _drafts = State(initialValue: record.segments.map {
            DraftSegment(id: $0.id, original: $0.original, translated: $0.translated, timestamp: $0.timestamp, isFinal: $0.isFinal)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if isEditing {
                    TextField("Course title", text: $title).font(.headline)
                } else {
                    Text(record.title).font(.headline)
                }
                Spacer()
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundColor(.secondary)
                if isEditing {
                    Button("Cancel", action: cancelEditing)
                    Button("Save", action: saveChanges).buttonStyle(.borderedProminent)
                } else {
                    Button("Edit") { isEditing = true }
                    Button("Done") { dismiss() }.buttonStyle(.bordered)
                }
            }.padding()

            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach($drafts) { $segment in
                        VStack(alignment: .leading, spacing: 7) {
                            if isEditing {
                                Text("Original").font(.caption).foregroundColor(.secondary)
                                TextEditor(text: $segment.original).frame(minHeight: 58)
                                Text("Translation").font(.caption).foregroundColor(.secondary)
                                TextEditor(text: $segment.translated).frame(minHeight: 58)
                            } else {
                                Text(segment.original).font(.system(size: 14, weight: .medium))
                                Text(segment.translated).font(.system(size: 13)).foregroundColor(.blue)
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    if drafts.isEmpty { ContentUnavailableView("No Transcript", systemImage: "text.quote") }
                }.padding()
            }

            Divider()
            HStack {
                Text(feedback.isEmpty ? "\(drafts.count) segments" : feedback)
                    .font(.caption).foregroundColor(feedback.isEmpty ? .secondary : .green)
                Spacer()
                Button { exportWord() } label: { Label("Export Word", systemImage: "doc.richtext") }
                    .buttonStyle(.borderedProminent).disabled(isEditing)
                if drafts.contains(where: { $0.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    Button { Task { await translateMissingSegments() } } label: {
                        Label(isFillingTranslations ? "Translating…" : "Translate Missing", systemImage: "character.bubble")
                    }
                    .disabled(isFillingTranslations || isEditing)
                }
                Button { ExportManager.exportSingle(record: record) } label: { Label("Export Text", systemImage: "doc.plaintext") }
                    .buttonStyle(.bordered).disabled(isEditing)
            }.padding()
        }
        .frame(minWidth: 620, minHeight: 480)
        .modifier(TranslationSessionCompat(manager: translationManager))
        .task {
            if drafts.contains(where: { $0.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                await translateMissingSegments()
            }
        }
    }

    private func saveChanges() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.title = cleanTitle.isEmpty ? record.title : cleanTitle
        record.segments = drafts.map {
            TranscriptSegment(id: $0.id, original: $0.original, translated: $0.translated, timestamp: $0.timestamp, isFinal: $0.isFinal)
        }
        historyStore.save()
        isEditing = false
        feedback = String(localized: "Changes saved")
    }

    private func cancelEditing() {
        title = record.title
        drafts = record.segments.map { DraftSegment(id: $0.id, original: $0.original, translated: $0.translated, timestamp: $0.timestamp, isFinal: $0.isFinal) }
        isEditing = false
    }

    private func exportWord() {
        feedback = String(localized: "Choose where to save…")
        ExportManager.exportWord(record: record) { result in
            switch result {
            case .success: feedback = String(localized: "Word document exported")
            case .failure(let error): feedback = error.localizedDescription
            }
        }
    }

    private func translateMissingSegments() async {
        guard !isFillingTranslations else { return }
        isFillingTranslations = true
        feedback = String(localized: "Translating missing text…")
        if !translationManager.hasSession {
            translationManager.requestSessionRefresh()
            for _ in 0..<10 where !translationManager.hasSession {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard translationManager.hasSession else {
            isFillingTranslations = false
            feedback = String(localized: "Translation service is not ready. Try again.")
            return
        }
        for index in drafts.indices where drafts[index].translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[index].translated = await translationManager.translate(drafts[index].original)
        }
        record.segments = drafts.map {
            TranscriptSegment(id: $0.id, original: $0.original, translated: $0.translated, timestamp: $0.timestamp, isFinal: $0.isFinal)
        }
        historyStore.save()
        isFillingTranslations = false
        feedback = String(localized: "Translations updated")
    }
}
