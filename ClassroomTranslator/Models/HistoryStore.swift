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
    /// 本次运行中被用户删除过的课程。录音页持有 course/record 引用，
    /// cascade 删除后再读它们的属性会让 SwiftData 直接 fatal error，
    /// 所以用"确认删除过"这种正向标记来拦截，而不是依赖 courses 列表的瞬时状态。
    private var deletedCourseIDs = Set<UUID>()

    /// 课程是否仍然可用（录音页据此决定还能不能碰 activeRecord）。
    func isCourseAlive(_ id: UUID) -> Bool {
        !deletedCourseIDs.contains(id)
    }

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
        // 先取 id：SwiftData 对象 delete 之后再读属性可能直接 fatal error。
        let courseID = course.id
        deletedCourseIDs.insert(courseID)
        // 级联删除会连带删掉课程下所有录音，同步清掉内存里的引用，
        // 免得其他视图（或录音页的 30s 检查点）继续渲染/写入已删除的记录。
        let cascadeRecordIDs = Set(records.filter { $0.course?.id == courseID }.map(\.id))
        modelContext?.delete(course)
        courses.removeAll { $0.id == courseID }
        if !cascadeRecordIDs.isEmpty {
            records.removeAll { cascadeRecordIDs.contains($0.id) }
        }
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
            isFinal: old.isFinal,
            speaker: old.speaker
        )
        record.segments = segments
    }

    /// 批量回写说话人标签（task-4）。只改内存里的 segmentsData，
    /// 落库交给现有 checkpoint 机制（30s 检查点 / finishRecord），不做逐条 save。
    /// - Parameter mapping: segmentID → 新显示名。
    func updateSpeakers(_ mapping: [UUID: String], in record: TranscriptRecord) {
        guard !mapping.isEmpty else { return }
        var segments = record.segments
        var changed = false
        for index in segments.indices {
            if let name = mapping[segments[index].id], segments[index].speaker != name {
                segments[index].speaker = name
                changed = true
            }
        }
        if changed { record.segments = segments }
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
        let recordID = record.id
        modelContext?.delete(record)
        records.removeAll { $0.id == recordID }
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
