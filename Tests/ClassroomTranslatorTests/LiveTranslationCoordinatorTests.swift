import XCTest
@testable import ClassroomTranslator

final class LiveTranslationCoordinatorTests: XCTestCase {
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
