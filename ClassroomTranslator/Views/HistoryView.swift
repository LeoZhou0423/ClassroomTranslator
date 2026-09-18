import SwiftUI

struct HistoryView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            
            Divider()
            
            if historyStore.records.isEmpty {
                emptyState
            } else {
                recordList
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Records Yet")
                .font(.title3)
                .foregroundColor(.secondary)
            
            Text("Your saved transcripts will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
    
    private var recordList: some View {
        List {
            ForEach(historyStore.records) { record in
                RecordRow(record: record)
            }
        }
        .listStyle(.plain)
    }
}

struct RecordRow: View {
    let record: TranscriptRecord
    @Environment(HistoryStore.self) private var historyStore
    @State private var showDetail = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(.headline)
                    
                    HStack {
                        Label(record.date.formatted(date: .abbreviated, time: .shortened),
                              systemImage: "calendar")
                        
                        Spacer()
                        
                        Label(formatDuration(record.duration), systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Menu {
                    Button(action: { showDetail = true }) {
                        Label("View", systemImage: "eye")
                    }
                    
                    Button(action: { ExportManager.exportSingle(record: record) }) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    
                    Divider()
                    
                    Button(role: .destructive, action: { deleteRecord() }) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            
            if showDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(record.segments) { segment in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(segment.original)
                                    .font(.subheadline)
                                
                                Text(segment.translated)
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }
        }
        .padding(.vertical, 4)
        .onTapGesture {
            withAnimation {
                showDetail.toggle()
            }
        }
    }
    
    private func deleteRecord() {
        historyStore.deleteRecord(record)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
