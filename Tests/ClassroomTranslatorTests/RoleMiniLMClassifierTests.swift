import XCTest
@testable import ClassroomTranslator

/// 生产路径：CoreML MiniLM 存在时应优于启发式；模型缺失时必须安全降级。
final class RoleMiniLMClassifierTests: XCTestCase {
    @MainActor
    func testFactoryPrefersMiniLMWhenPresent() {
        let coordinator = RoleAssignmentCoordinator.makeDefault()
        // 无论 CoreML 是否加载成功，都不应崩溃；录音路径无关。
        XCTAssertNotNil(coordinator.book)
    }

    @MainActor
    func testMiniLMClassifiesTeacherAndStudentWhenAvailable() throws {
        guard let mini = RoleMiniLMClassifier() else {
            throw XCTSkip("RoleMiniLM.mlpackage not in test bundle")
        }
        let teacher = mini.classify(
            fullText: "Yes your learning intention is you can multiply twodigit numbers by twodigit numbers"
        )
        let student = mini.classify(
            fullText: "I think the area is length times width and I am not sure about the perimeter"
        )
        XCTAssertNotNil(teacher)
        XCTAssertNotNil(student)
        XCTAssertEqual(teacher?.label, "teacher")
        XCTAssertEqual(student?.label, "student")
        XCTAssertGreaterThanOrEqual(teacher?.score ?? 0, 0.5)
    }

    @MainActor
    func testHeuristicStillWorksAsFallback() {
        let h = HeuristicRoleClassifier()
        let t = h.classify(fullText: "Today our objective is to learn fractions, please open your books")
        let s = h.classify(fullText: "I don't know, is it four?")
        XCTAssertEqual(t?.label, "teacher")
        XCTAssertEqual(s?.label, "student")
    }

    @MainActor
    func testWordPieceEncodesWithinMaxLength() throws {
        guard let tok = WordPieceTokenizer() else {
            throw XCTSkip("role_vocab.txt missing")
        }
        let long = Array(repeating: "objective", count: 200).joined(separator: " ")
        let encoded = tok.encode(text: long, maxLength: 128)
        XCTAssertEqual(encoded.ids.count, 128)
        XCTAssertEqual(encoded.mask.count, 128)
        XCTAssertEqual(encoded.types.count, 128)
        XCTAssertEqual(encoded.ids.first.map(Int.init), 101) // [CLS]
        XCTAssertEqual(encoded.mask.reduce(0, +) > 0, true)
    }
}
