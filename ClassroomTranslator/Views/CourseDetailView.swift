import SwiftUI

struct CourseDetailView: View {
    @Environment(HistoryStore.self) private var historyStore
    let course: Course

    @Environment(\.dismiss) private var dismiss
    @State private var showRecording = false
    @State private var showDeleteConfirm = false

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
                    Label("New Recording", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Transcript content
            if let record = latestRecord, !record.segments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 英文全文
                        Text(record.fullTranscript)
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                        // 中文全文
                        Text(record.fullTranslation)
                            .font(.system(size: 15))
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(8)
                    }
                    .padding()
                }
            } else {
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
            }
        }
        .navigationDestination(isPresented: $showRecording) {
            RecordingHost(course: course, historyStore: historyStore) {
                showRecording = false
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive, action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete Course",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                historyStore.deleteCourse(course)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete this course? All recordings will be removed.")
        }
    }
}
