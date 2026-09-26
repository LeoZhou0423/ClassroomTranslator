import XCTest
@testable import ClassroomTranslator

final class HistoryStoreTests: XCTestCase {
    @MainActor
    func testEachRecordingCreatesASeparateRecord() {
        let store = HistoryStore(isStoredInMemoryOnly: true)
        let course = Course(name: "Test")
        store.addCourse(course)
        let first = store.startNewRecord(in: course)
        let second = store.startNewRecord(in: course)
        let third = store.startNewRecord(in: course)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(second.id, third.id)
        store.finishRecord(first, duration: 10)
        store.finishRecord(second, duration: 20)
        store.finishRecord(third, duration: 30)
        XCTAssertEqual(store.recordsForCourse(course).count, 3)
    }

    @MainActor
    func testCheckpointPersistsDurationAndSegments() {
        let store = HistoryStore(isStoredInMemoryOnly: true)
        let course = Course(name: "Test")
        store.addCourse(course)
        let record = store.startNewRecord(in: course)
        store.addSegmentIfNew(TranscriptSegment(original: "Hello", translated: "你好"), to: record)
        store.checkpoint(record, duration: 12)
        XCTAssertEqual(record.duration, 12, accuracy: 0.001)
        XCTAssertEqual(record.segments.count, 1)
    }

    /// 录音页通过 isCourseAlive 决定还能不能碰 activeRecord，
    /// 删除课程后必须立刻返回 false，并把级联删除的记录从内存列表里摘掉。
    @MainActor
    func testDeletingCourseMarksItDeadAndDropsCascadedRecords() {
        let store = HistoryStore(isStoredInMemoryOnly: true)
        let course = Course(name: "Test")
        store.addCourse(course)
        let record = store.startNewRecord(in: course)
        store.addSegmentIfNew(TranscriptSegment(original: "Hello", translated: "你好"), to: record)
        store.checkpoint(record, duration: 5)
        store.fetchRecords()

        let courseID = course.id
        let recordID = record.id
        XCTAssertTrue(store.isCourseAlive(courseID))
        XCTAssertEqual(store.records.count, 1)

        store.deleteCourse(course)

        XCTAssertFalse(store.isCourseAlive(courseID))
        XCTAssertFalse(store.courses.contains { $0.id == courseID })
        XCTAssertFalse(store.records.contains { $0.id == recordID })
    }

    @MainActor
    func testMissingCourseTargetGetsMigratedWithoutDroppingCourse() {
        let store = HistoryStore(isStoredInMemoryOnly: true)
        let course = Course(name: "Legacy")
        course.targetLanguageCode = nil
        store.addCourse(course)
        XCTAssertNotNil(course.targetLanguageCode)
        XCTAssertTrue(store.courses.contains(where: { $0.id == course.id }))
    }
}
