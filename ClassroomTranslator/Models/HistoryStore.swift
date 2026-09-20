import Foundation
import SwiftData
import SwiftUI
import Observation

@MainActor
@Observable
final class HistoryStore {
    var courses: [Course] = []
    var records: [TranscriptRecord] = []
    var lastErrorMessage = ""
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    /// 防止 save() → fetchRecords() 同步通知观察者导致布局重入
    private var isSaving = false

    init(isStoredInMemoryOnly: Bool = false) {
        setupContainer(isStoredInMemoryOnly: isStoredInMemoryOnly)
    }

    private func setupContainer(isStoredInMemoryOnly: Bool) {
        let config = ModelConfiguration(isStoredInMemoryOnly: isStoredInMemoryOnly)
        do {
            modelContainer = try ModelContainer(for: Course.self, TranscriptRecord.self, configurations: config)
            modelContext = modelContainer?.mainContext
            fetchCourses()
            fetchRecords()
            migrateCourseTargetsIfNeeded()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Course

    func fetchCourses() {
        let descriptor = FetchDescriptor<Course>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        do {
            courses = try modelContext?.fetch(descriptor) ?? []
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func addCourse(_ course: Course) {
        if course.targetLanguageCode == nil {
            course.targetLanguageCode = UserDefaults.standard.string(forKey: "translationTarget") ?? "zh-Hans"
        }
        modelContext?.insert(course)
        if !courses.contains(where: { $0.id == course.id }) { courses.insert(course, at: 0) }
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
            lastErrorMessage = error.localizedDescription
        }
    }

    func recordsForCourse(_ course: Course) -> [TranscriptRecord] {
        records.filter { $0.course?.id == course.id }
    }

    @discardableResult
    func startNewRecord(in course: Course, title: String = "") -> TranscriptRecord {
        let record = TranscriptRecord(date: Date(), title: title.isEmpty ? formatTitle(Date()) : title)
        record.course = course
        modelContext?.insert(record)
        checkpoint(record)
        return record
    }

    func addSegmentIfNew(_ segment: TranscriptSegment, to record: TranscriptRecord) {
        var segs = record.segments
        if segs.contains(where: { $0.id == segment.id }) { return }
        segs.append(segment)
        record.segments = segs
    }

    func updateTranslation(for segmentID: UUID, to translation: String, in record: TranscriptRecord) {
        var segments = record.segments
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let old = segments[index]
        segments[index] = TranscriptSegment(
            id: old.id,
            original: old.original,
            translated: translation,
            timestamp: old.timestamp,
            isFinal: old.isFinal
        )
        record.segments = segments
    }

    func checkpoint(_ record: TranscriptRecord, duration: TimeInterval? = nil) {
        if let duration { record.duration = duration }
        do {
            try modelContext?.save()
            lastErrorMessage = ""
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func finishRecord(_ record: TranscriptRecord, duration: TimeInterval) {
        checkpoint(record, duration: duration)
        fetchCourses()
        fetchRecords()
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
        do {
            try modelContext?.save()
            lastErrorMessage = ""
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        // 延迟 fetch，让当前布局完成
        Task { @MainActor in
            self.fetchCourses()
            self.fetchRecords()
        }
    }

    private func migrateCourseTargetsIfNeeded() {
        let fallback = UserDefaults.standard.string(forKey: "translationTarget") ?? "zh-Hans"
        var changed = false
        for course in courses where course.targetLanguageCode == nil {
            course.targetLanguageCode = fallback
            changed = true
        }
        if changed { checkpointMigration() }
    }

    private func checkpointMigration() {
        do { try modelContext?.save() }
        catch { lastErrorMessage = error.localizedDescription }
    }

    private func formatTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
