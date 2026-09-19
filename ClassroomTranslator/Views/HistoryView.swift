import SwiftUI

@MainActor
struct HistoryView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }.padding()
            Divider()
            if historyStore.records.isEmpty { emptyState } else { recordList }
        }.frame(minWidth: 500, minHeight: 400)
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
        List { ForEach(historyStore.records) { record in RecordRow(record: record) } }.listStyle(.plain)
    }
}

@MainActor
struct RecordRow: View {
    let record: TranscriptRecord
    @Environment(HistoryStore.self) private var historyStore
    @State private var showDetail = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.headline)
                    HStack {
                        Label(record.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        Spacer()
                        Label(formatDuration(record.duration), systemImage: "clock")
                    }.font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    Button(action: { showDetail = true }) { Label("View or Edit", systemImage: "pencil") }
                    Button(action: { ExportManager.exportWord(record: record) }) { Label("Export Word", systemImage: "doc.richtext") }
                    Button(action: { ExportManager.exportSingle(record: record) }) { Label("Export Text", systemImage: "doc.plaintext") }
                    Divider()
                    Button(role: .destructive) { historyStore.deleteRecord(record) } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) { SessionDetailView(record: record) }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600; let minutes = (Int(duration) % 3600) / 60; let seconds = Int(duration) % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}
