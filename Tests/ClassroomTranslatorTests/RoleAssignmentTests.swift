import XCTest
@testable import ClassroomTranslator

/// 身份判定：置信度门槛 / 结束强制定案 / 低置信全文合并重判 / 多人角色写入。
final class RoleAssignmentTests: XCTestCase {
    @MainActor
    func testWaitsWhenConfidenceLow() {
        var st = RoleAssignmentState()
        let policy = RoleAssignmentPolicy()
        _ = st.append("hi", policy: policy)
        _ = st.append("ok", policy: policy)
        let d = st.consider(label: "teacher", score: 0.55, policy: policy, forced: false)
        XCTAssertNil(d)
        XCTAssertNil(st.decision)
    }

    @MainActor
    func testHighConfidenceWritesThenMarks() {
        var st = RoleAssignmentState()
        let policy = RoleAssignmentPolicy()
        _ = st.append("Today our objective is to learn fractions", policy: policy)
        _ = st.append("Please open your books to page twelve", policy: policy)
        let d = st.consider(label: "teacher", score: 0.91, policy: policy, forced: false)
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.role, .teacher)
        XCTAssertEqual(d?.confidence, .high)
        XCTAssertTrue(st.decision?.isHighConfidence ?? false)
    }

    @MainActor
    func testFinalizeForcesLowWhenThinEvidence() {
        var st = RoleAssignmentState()
        let policy = RoleAssignmentPolicy()
        _ = st.append("ok", policy: policy)
        let d = st.finalizeWithClassifierResult(label: "student", score: 0.7, policy: policy)
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.confidence, .low)
        XCTAssertEqual(d?.forced, true)
    }

    @MainActor
    func testLowConfidenceRecheckUsesCombinedText() {
        var st = RoleAssignmentState()
        let policy = RoleAssignmentPolicy()
        _ = st.append("umm", policy: policy)
        _ = st.append("maybe", policy: policy)
        _ = st.consider(label: "student", score: 0.6, policy: policy, forced: true)
        XCTAssertEqual(st.decision?.confidence, .low)

        let should = st.append(
            "Okay so our objective is to produce mathematical solutions today",
            policy: policy
        )
        XCTAssertTrue(should)
        XCTAssertTrue(st.needsRecheck)
        XCTAssertTrue(st.combinedText.contains("objective"))
        XCTAssertTrue(st.combinedText.contains("umm"))
    }

    @MainActor
    func testMultiTeachersStayDistinctInAliases() {
        let book = RoleAssignmentBook()
        book.policy.highConfidence = 0.5
        book.classify = { text in
            if text.contains("objective") { return ("teacher", 0.95) }
            return ("student", 0.9)
        }
        _ = book.ingest(utterance: "Our objective today is geometry", person: "T1")
        _ = book.ingest(utterance: "Remember the formula", person: "T1")
        _ = book.ingest(utterance: "Your objective is algebra practice", person: "T2")
        _ = book.ingest(utterance: "Please begin the warm-up", person: "T2")
        _ = book.ingest(utterance: "I think it is four", person: "S1")
        _ = book.ingest(utterance: "We got seven", person: "S1")

        let decisions = book.finalizeAll()
        XCTAssertEqual(decisions["T1"]?.role, .teacher)
        XCTAssertEqual(decisions["T2"]?.role, .teacher)
        XCTAssertEqual(decisions["S1"]?.role, .student)

        var map: [String: SpeakerAlias] = [:]
        let coord = RoleAssignmentCoordinator(classifier: HeuristicRoleClassifier())
        coord.applyToAliases(decisions: decisions, into: &map, order: ["T1", "T2", "S1"])
        XCTAssertEqual(map["T1"]?.role, .teacher)
        XCTAssertEqual(map["T2"]?.role, .teacher)
        XCTAssertEqual(map["S1"]?.role, .student)
        // UI 显示：多老师/多学生加序号
        XCTAssertEqual(map["T1"]?.nickname, RoleDisplayNames.teacherName(1))
        XCTAssertEqual(map["T2"]?.nickname, RoleDisplayNames.teacherName(2))
        XCTAssertEqual(map["S1"]?.nickname, RoleDisplayNames.studentName(1))
        XCTAssertEqual(map["T1"]?.roleConfidence, RoleConfidence.high.rawValue)
    }

    @MainActor
    func testRecheckSendsFullCombinedText() {
        let book = RoleAssignmentBook()
        book.policy.highConfidence = 0.99
        book.classify = { text in
            let score = text.contains("objective") ? 0.99 : 0.7
            return ("teacher", score)
        }
        _ = book.ingest(utterance: "hello", person: "P")
        _ = book.ingest(utterance: "well", person: "P")
        let forced = book.finalizeAll()
        XCTAssertEqual(forced["P"]?.confidence, .low)

        _ = book.ingest(utterance: "Our objective is to explore functions carefully", person: "P")
        let again = book.recheckLowConfidence()
        XCTAssertEqual(again["P"]?.role, .teacher)
        XCTAssertEqual(again["P"]?.confidence, .high)
        XCTAssertEqual(again["P"]?.evidenceText.contains("hello"), true)
        XCTAssertEqual(again["P"]?.evidenceText.contains("objective"), true)
    }
}
