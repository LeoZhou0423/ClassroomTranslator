import XCTest
@testable import ClassroomTranslator

final class RecordingStartupStepTests: XCTestCase {
    @MainActor
    func testSuccessCancelsTimeout() async {
        var timedOut = false
        let error = await RecordingStartupStep.run(
            timeoutNanoseconds: 20_000_000,
            onTimeout: { timedOut = true },
            operation: {}
        )
        XCTAssertNil(error)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(timedOut)
    }

    @MainActor
    func testOperationErrorIsPreserved() async {
        enum Failure: Error { case unavailable }
        let error = await RecordingStartupStep.run(
            timeoutNanoseconds: 1_000_000_000,
            onTimeout: { XCTFail("An immediate failure must not time out") },
            operation: { throw Failure.unavailable }
        )
        XCTAssertTrue(error is Failure)
    }

    @MainActor
    func testTimeoutReturnsBeforeUncooperativeOperationAndIgnoresLateSuccess() async {
        var pending: CheckedContinuation<Void, Never>?
        var timeoutCount = 0
        let returned = expectation(description: "Timeout releases the caller")
        let operationEnded = expectation(description: "Late operation finishes safely")
        let caller = Task { @MainActor in
            let error = await RecordingStartupStep.run(
                timeoutNanoseconds: 20_000_000,
                onTimeout: { timeoutCount += 1 },
                operation: {
                    await withCheckedContinuation { pending = $0 }
                    operationEnded.fulfill()
                }
            )
            XCTAssertTrue(error is RecordingStartupStep.StartupError)
            XCTAssertEqual(timeoutCount, 1)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertNotNil(pending)
        pending?.resume()
        await fulfillment(of: [operationEnded], timeout: 2)
        await caller.value
        XCTAssertEqual(timeoutCount, 1)
    }
}
