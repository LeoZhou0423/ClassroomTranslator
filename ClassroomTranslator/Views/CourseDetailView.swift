import SwiftUI

struct CourseDetailView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    let course: Course

    @State private var showRecording = false
    @State private var showDeleteConfirm = false
    @State private var recordingTranslationManager = TranslationManager()

    var body: some View {
        Group {
            if showRecording {
                StableRecordingView(
                    course: course,
                    historyStore: historyStore,
                    translationManager: recordingTranslationManager,
                    onClose: { showRecording = false }
                )
                .modifier(TranslationSessionCompat(manager: recordingTranslationManager))
            } else {
                courseOverview
            }
        }
        .toolbar {
            if !showRecording {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive, action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog("Delete Course", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                historyStore.deleteCourse(course)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete this course? All recordings will be removed.")
        }
    }

    private var courseOverview: some View {
        let latestRecord = historyStore.recordsForCourse(course).first
        return VStack(spacing: 0) {
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
            if let record = latestRecord, !record.segments.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(record.fullTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                        Text(record.fullTranslation)
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
                    Text("No recordings yet").foregroundColor(.secondary)
                    Button("Start First Recording") { showRecording = true }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
