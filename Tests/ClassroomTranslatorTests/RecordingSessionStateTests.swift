import XCTest
@testable import ClassroomTranslator

final class RecordingSessionStateTests: XCTestCase {
    func testPauseAndResumeExcludePausedTime() {
        var state = RecordingSessionState()
        let start = Date(timeIntervalSince1970: 100)
        state.beginStarting()
        state.start(at: start)
        state.pause(at: start.addingTimeInterval(10))
        state.beginStarting()
        state.start(at: start.addingTimeInterval(30))
        state.end(at: start.addingTimeInterval(35))
        XCTAssertEqual(state.elapsed(at: start.addingTimeInterval(99)), 15, accuracy: 0.001)
        XCTAssertEqual(state.phase, .ended)
    }

    func testInterruptionAccumulatesElapsedTime() {
        var state = RecordingSessionState()
        let start = Date(timeIntervalSince1970: 200)
        state.beginStarting()
        state.start(at: start)
        state.interrupt(at: start.addingTimeInterval(7))
        XCTAssertEqual(state.elapsed(), 7, accuracy: 0.001)
        XCTAssertEqual(state.phase, .interrupted)
    }

    func testFailedResumeKeepsSessionResumable() {
        var state = RecordingSessionState()
        state.beginStarting()
        state.start(at: .init(timeIntervalSince1970: 0))
        state.pause(at: .init(timeIntervalSince1970: 4))
        state.beginStarting()
        state.failStart(resumable: true)
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.elapsed(), 4, accuracy: 0.001)
    }
}
