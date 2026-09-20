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
}
