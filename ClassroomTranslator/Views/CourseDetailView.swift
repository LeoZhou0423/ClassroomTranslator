import SwiftUI

struct CourseDetailView: View {
    @Environment(HistoryStore.self) private var historyStore
    let course: Course

    @State private var showRecording = false

    private var courseRecords: [TranscriptRecord] {
        historyStore.recordsForCourse(course)
    }

    private var latestRecord: TranscriptRecord? {
        courseRecords.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(course.name).font(.title2).bold()
                    Label(course.accentName, systemImage: "waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { showRecording = true }) {
                    Label(String(localized: "New Recording"), systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Transcript content
            if let record = latestRecord, !record.segments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(record.segments) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(segment.original)
                                    .font(.system(size: 14, weight: .medium))
                                Text(segment.translated)
                                    .font(.system(size: 13))
                                    .foregroundColor(.blue)
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "mic.circle")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text(String(localized: "No recordings yet"))
                        .foregroundColor(.secondary)
                    Button(String(localized: "Start First Recording")) { showRecording = true }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showRecording) {
            RecordingView(course: course)
        }
    }
}
