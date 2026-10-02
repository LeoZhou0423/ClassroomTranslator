import XCTest
@testable import ClassroomTranslator

final class LiveTranslationCoordinatorTests: XCTestCase {
    @MainActor
    func testRevisionSupersedesInFlightAndPendingTranslations() async {
        var continuation: CheckedContinuation<String, Never>?
        var inputs: [String] = []
        var outputs: [String] = []
        let coordinator = LiveTranslationCoordinator(partialInterval: .zero) { text in
            inputs.append(text)
            if text == "office." { return await withCheckedContinuation { continuation = $0 } }
            return "T:" + text
        }
        let id = UUID()
        coordinator.submit(.init(kind: .final, text: "office.", cue: "", revision: 1, generation: 1, segmentID: id) { outputs.append($0.translatedText) })
        for _ in 0..<200 where continuation == nil { await Task.yield() }
        guard let continuation else { XCTFail("Translator never started"); coordinator.cancelAll(); return }
        coordinator.submit(.init(kind: .final, text: "office hours", cue: "", revision: 1, generation: 1, segmentID: id) { outputs.append($0.translatedText) })
        coordinator.submit(.init(kind: .final, text: "office hours, ask questions.", cue: "", revision: 1, generation: 1, segmentID: id) { outputs.append($0.translatedText) })
        continuation.resume(returning: "Wrong office")
        await coordinator.waitUntilIdle()
        XCTAssertEqual(inputs, ["office.", "office hours, ask questions."])
        XCTAssertEqual(outputs, ["T:office hours, ask questions."])
    }

    @MainActor
    func testContextIsIncludedInTranslationCacheIdentity() async {
        var calls = 0
        let coordinator = LiveTranslationCoordinator(partialInterval: .zero, contextualTranslator: { text, context in
            calls += 1
            return context + text
        })
        for context in ["Course", "Course", "Different course"] {
            coordinator.submit(.init(kind: .final, text: "176", cue: "", revision: 1, generation: 1, context: context) { _ in })
        }
        await coordinator.waitUntilIdle()
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testIdenticalFinalTextIsTranslatedOnlyOnce() async {
        var calls = 0
        var outputs: [String] = []
        let coordinator = LiveTranslationCoordinator(partialInterval: .zero) { text in
            calls += 1
            return "T:\(text)"
        }
        for revision in 1...2 {
            coordinator.submit(.init(kind: .final, text: "Same sentence.", cue: "Same sentence.", revision: revision, generation: 1) {
                outputs.append($0.translatedText)
            })
        }
        await coordinator.waitUntilIdle()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outputs, ["T:Same sentence.", "T:Same sentence."])
    }

    @MainActor
    func testPendingPartialsCoalesceToLatest() async {
        var translatedInputs: [String] = []
        var outputs: [String] = []
        let coordinator = LiveTranslationCoordinator(partialInterval: .zero) { text in
            translatedInputs.append(text)
            return "T:\(text)"
        }
        for value in ["one", "one two", "one two three"] {
            coordinator.submit(.init(kind: .partial, text: value, cue: value, revision: 1, generation: 1) {
                outputs.append($0.translatedText)
            })
        }
        await coordinator.waitUntilIdle()
        XCTAssertEqual(translatedInputs.last, "one two three")
        XCTAssertEqual(outputs.last, "T:one two three")
        XCTAssertLessThanOrEqual(translatedInputs.count, 2)
    }

    @MainActor
    func testFinalRequestsPreserveOrder() async {
        var outputs: [String] = []
        let coordinator = LiveTranslationCoordinator(partialInterval: .zero) { "T:\($0)" }
        for (index, value) in ["first", "second"].enumerated() {
            coordinator.submit(.init(kind: .final, text: value, cue: value, revision: index, generation: 1) {
                outputs.append($0.translatedText)
            })
        }
        await coordinator.waitUntilIdle()
        XCTAssertEqual(outputs, ["T:first", "T:second"])
    }

    @MainActor
    func testPendingCountIncludesTranslationAlreadyInFlight() async {
        var continuation: CheckedContinuation<String, Never>?
        let coordinator = LiveTranslationCoordinator(partialInterval: .zero) { _ in
            await withCheckedContinuation { continuation = $0 }
        }
        coordinator.submit(.init(kind: .final, text: "lesson", cue: "lesson", revision: 1, generation: 1) { _ in })
        for _ in 0..<200 where continuation == nil { await Task.yield() }
        guard let continuation else {
            XCTFail("Translator did not start")
            coordinator.cancelAll()
            return
        }
        XCTAssertEqual(coordinator.pendingCount, 1)
        continuation.resume(returning: "课程")
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    @MainActor
    func testFinalTranslationRetriesOneTransientEmptyResult() async {
        var attempts = 0
        var output = ""
        let coordinator = LiveTranslationCoordinator(partialInterval: .zero) { _ in
            attempts += 1
            return attempts == 1 ? "" : "课程内容"
        }
        coordinator.submit(.init(kind: .final, text: "lesson content", cue: "lesson content", revision: 1, generation: 1) {
            output = $0.translatedText
        })
        await coordinator.waitUntilIdle()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(output, "课程内容")
    }

    @MainActor
    func testOldGenerationResultCannotOverwriteNewSession() async {
        var continuation: CheckedContinuation<String, Never>?
        var outputs: [String] = []
        let coordinator = LiveTranslationCoordinator(partialInterval: .zero) { _ in
            await withCheckedContinuation { continuation = $0 }
        }
        coordinator.submit(.init(kind: .partial, text: "old", cue: "old", revision: 1, generation: 1) {
            outputs.append($0.translatedText)
        })
        for _ in 0..<10 where continuation == nil { await Task.yield() }
        guard let continuation else {
            XCTFail("Translator did not start")
            coordinator.cancelAll()
            return
        }
        coordinator.activateGeneration(2)
        continuation.resume(returning: "stale")
        await coordinator.waitUntilIdle()
        XCTAssertTrue(outputs.isEmpty)
    }

    /// cancelAll() 会把 worker 引用置空；旧任务收尾时若不校验身份，
    /// 会把新 worker 的引用也清掉，waitUntilIdle() 就会提前返回（译文没落库）。
    @MainActor
    func testCancelledWorkerCannotClearItsSuccessor() async {
        var firstContinuation: CheckedContinuation<String, Never>?
        var outputs: [String] = []
        let coordinator = LiveTranslationCoordinator(partialInterval: .zero) { text in
            if text == "first" {
                return await withCheckedContinuation { firstContinuation = $0 }
            }
            return "T:\(text)"
        }

        coordinator.submit(.init(kind: .final, text: "first", cue: "first", revision: 1, generation: 1) {
            outputs.append($0.translatedText)
        })
        for _ in 0..<200 where firstContinuation == nil { await Task.yield() }
        guard let firstContinuation else {
            XCTFail("Translator never started")
            coordinator.cancelAll()
            return
        }

        coordinator.cancelAll()
        coordinator.submit(.init(kind: .final, text: "second", cue: "second", revision: 2, generation: 1) {
            outputs.append($0.translatedText)
        })
        firstContinuation.resume(returning: "stale")

        await coordinator.waitUntilIdle()
        XCTAssertEqual(outputs, ["T:second"])
    }
}
