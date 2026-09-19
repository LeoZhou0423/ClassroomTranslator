import Foundation
import SwiftData
import SwiftUI
import Observation

@MainActor
@Observable
final class HistoryStore {
    var courses: [Course] = []
    var records: [TranscriptRecord] = []
    @ObservationIgnored private(set) var currentRecord: TranscriptRecord?
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    /// 防止 save() → fetchRecords() 同步通知观察者导致布局重入
    private var isSaving = false

    init() {
        setupContainer()
    }

    private func setupContainer() {
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: Course.self, TranscriptRecord.self, configurations: config)
            modelContext = modelContainer?.mainContext
            fetchCourses()
            fetchRecords()
        } catch {
            print("Failed to setup model container: \(error)")
        }
    }

    // MARK: - Course

    func fetchCourses() {
        let descriptor = FetchDescriptor<Course>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        do {
            courses = try modelContext?.fetch(descriptor) ?? []
        } catch {
            print("Failed to fetch courses: \(error)")
        }
    }

    func addCourse(_ course: Course) {
        modelContext?.insert(course)
        save()
    }

    func deleteCourse(_ course: Course) {
        modelContext?.delete(course)
        courses.removeAll { $0.id == course.id }
        save()
    }

    // MARK: - Record

    func fetchRecords() {
        let descriptor = FetchDescriptor<TranscriptRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        do {
            records = try modelContext?.fetch(descriptor) ?? []
        } catch {
            print("Failed to fetch records: \(error)")
        }
    }

    func recordsForCourse(_ course: Course) -> [TranscriptRecord] {
        records.filter { $0.course?.id == course.id }
    }

    func startNewRecord(in course: Course, title: String = "") {
        if let existing = recordsForCourse(course).first {
            currentRecord = existing
            return
        }
        let record = TranscriptRecord(date: Date(), title: title.isEmpty ? formatTitle(Date()) : title)
        record.course = course
        currentRecord = record
        modelContext?.insert(record)
        // Keep recording startup free of SwiftData saves and observable array
        // refreshes. On macOS 26/27 those updates can re-enter the hidden
        // CourseDetailView while RecordingView is being laid out.
    }

    func addSegmentIfNew(_ segment: TranscriptSegment) {
        guard let record = currentRecord else { return }
        var segs = record.segments
        if let last = segs.last, last.original == segment.original { return }
        segs.append(segment)
        record.segments = segs
        record.duration = Date().timeIntervalSince(record.date)
        // 延迟到下一个 runloop，避免 save() → fetchRecords() 同步通知
        // 观察者导致布局期间 view graph invalidation
        Task { @MainActor in save() }
    }

    func addSegment(_ segment: TranscriptSegment) {
        addSegmentIfNew(segment)
    }

    func stopCurrentRecord() {
        currentRecord = nil
        save()
    }

    func deleteRecord(_ record: TranscriptRecord) {
        modelContext?.delete(record)
        records.removeAll { $0.id == record.id }
        save()
    }

    func save() {
        guard !isSaving else { return } // 防重入
        isSaving = true
        defer { isSaving = false }
        try? modelContext?.save()
        // 延迟 fetch，让当前布局完成
        Task { @MainActor in
            self.fetchCourses()
            self.fetchRecords()
        }
    }

    private func formatTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
