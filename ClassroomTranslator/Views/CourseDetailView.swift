import SwiftUI

struct CourseDetailView: View {
    @Environment(HistoryStore.self) private var historyStore
    let course: Course

    @State private var showRecording = false
    @State private var showSessionDetail = false
    @State private var selectedRecord: TranscriptRecord?

    private var sessions: [TranscriptRecord] {
        historyStore.recordsForCourse(course)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(course.name).font(.title2).bold()
                    HStack(spacing: 12) {
                        Label(course.accentName, systemImage: "waveform")
                        Label("\(sessions.count) sessions", systemImage: "doc.text")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { showRecording = true }) {
                    Label("New Recording", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Sessions list
            if sessions.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "mic.circle")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text("No recordings yet")
                        .foregroundColor(.secondary)
                    Button("Start First Recording") { showRecording = true }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sessions) { record in
                        Button(action: {
                            selectedRecord = record
                            showSessionDetail = true
                        }) {
                            sessionRow(record)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteSessions)
                }
            }
        }
        .sheet(isPresented: $showRecording) {
            RecordingView(course: course)
        }
        .sheet(isPresented: $showSessionDetail) {
            if let record = selectedRecord {
                SessionDetailView(record: record)
            }
        }
    }

    private func sessionRow(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.title)
                .font(.headline)
                .foregroundColor(.primary)
            HStack(spacing: 12) {
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(formatDuration(record.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(record.segments.count) segments")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !record.fullTranscript.isEmpty {
                Text(String(record.fullTranscript.prefix(80)) + (record.fullTranscript.count > 80 ? "…" : ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            historyStore.deleteRecord(sessions[index])
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
