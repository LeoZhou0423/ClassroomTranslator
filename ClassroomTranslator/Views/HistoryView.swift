import SwiftUI

@MainActor
struct HistoryView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    var showsDoneButton = true
    @State private var searchText = ""
    @State private var selectedRecord: TranscriptRecord?
    @State private var recordToDelete: TranscriptRecord?
    @State private var exportFeedback = ""
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                if showsDoneButton { Button("Done") { dismiss() }.buttonStyle(.bordered) }
            }.padding()
            Divider()
            if filteredRecords.isEmpty { emptyState } else { recordList }
        }
        .frame(minWidth: 500, minHeight: 400)
        .searchable(text: $searchText, prompt: "Search recordings")
        .sheet(item: $selectedRecord) { SessionDetailView(record: $0) }
        .confirmationDialog("Delete Recording", isPresented: Binding(
            get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let recordToDelete { historyStore.deleteRecord(recordToDelete) }
                recordToDelete = nil
            }
            Button("Cancel", role: .cancel) { recordToDelete = nil }
        } message: { Text("This recording and its transcript will be permanently deleted.") }
        .alert("Export", isPresented: Binding(
            get: { !exportFeedback.isEmpty }, set: { if !$0 { exportFeedback = "" } }
        )) {
            Button("OK") { exportFeedback = "" }
        } message: { Text(exportFeedback) }
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 48)).foregroundColor(.secondary)
            Text("No Records Yet").font(.title3).foregroundColor(.secondary)
            Text("Your saved transcripts will appear here").font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
    }
    
    private var recordList: some View {
        List {
            ForEach(filteredRecords) { record in
                RecordRow(
                    record: record,
                    onOpen: { selectedRecord = record },
                    onDelete: { recordToDelete = record },
                    onExportFeedback: { exportFeedback = $0 }
                )
            }
        }.listStyle(.plain)
    }

    private var filteredRecords: [TranscriptRecord] {
        guard !searchText.isEmpty else { return historyStore.records }
        // segments 每次访问都要全量解一次 JSON；原来 fullTranscript + fullTranslation
        // 会各解一遍，搜索时主线程开销直接翻倍，这里合并成一次解码。
        return historyStore.records.filter { record in
            if record.title.localizedCaseInsensitiveContains(searchText) { return true }
            if record.course?.name.localizedCaseInsensitiveContains(searchText) == true { return true }
            let segments = record.segments
            let transcript = segments.map { $0.original }.joined(separator: " ")
            let translation = segments.map { $0.translated }.joined(separator: " ")
            return transcript.localizedCaseInsensitiveContains(searchText)
                || translation.localizedCaseInsensitiveContains(searchText)
        }
    }
}

@MainActor
struct RecordRow: View {
    let record: TranscriptRecord
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onExportFeedback: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.headline)
                    if let courseName = record.course?.name {
                        Text(courseName).font(.caption).foregroundColor(.secondary)
                    }
                    HStack {
                        Label(record.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        Spacer()
                        Label(formatDuration(record.duration), systemImage: "clock")
                    }.font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    Button(action: onOpen) { Label("View or Edit", systemImage: "pencil") }
                    Button(action: exportWord) { Label("Export Word", systemImage: "doc.richtext") }
                    Button(action: exportText) { Label("Export Text", systemImage: "doc.plaintext") }
                    Divider()
                    Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        // VIS-09：统一 h:mm:ss，与录音页、导出文本完全一致。
        let total = max(0, Int(duration))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func exportWord() {
        ExportManager.exportWord(record: record) { onExportFeedback(exportMessage(for: $0)) }
    }

    private func exportText() {
        ExportManager.exportSingle(record: record) { onExportFeedback(exportMessage(for: $0)) }
    }

    private func exportMessage(for result: Result<URL, Error>) -> String {
        switch result {
        case .success(let url): return String(localized: "Exported successfully: \(url.lastPathComponent)")
        case .failure(let error):
            // UX-07：取消返回空串 —— alert 的 isPresented 绑定非空才触发，因此完全静默。
            return ExportManager.isCancellation(error) ? "" : error.localizedDescription
        }
    }
}
