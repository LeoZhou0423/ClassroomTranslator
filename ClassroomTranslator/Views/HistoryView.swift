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
        return historyStore.records.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.course?.name.localizedCaseInsensitiveContains(searchText) == true
                || $0.fullTranscript.localizedCaseInsensitiveContains(searchText)
                || $0.fullTranslation.localizedCaseInsensitiveContains(searchText)
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
        let hours = Int(duration) / 3600; let minutes = (Int(duration) % 3600) / 60; let seconds = Int(duration) % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
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
        case .failure(let error): return error.localizedDescription
        }
    }
}
