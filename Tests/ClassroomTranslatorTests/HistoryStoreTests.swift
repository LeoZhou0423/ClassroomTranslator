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
