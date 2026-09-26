import XCTest
@testable import ClassroomTranslator

/// PSY-02：错误 → 人话映射。只要保证不把技术串漏给用户即可。
/// 标 @MainActor：测试里会构造 RecordingStartupStep.StartupError（外层类型是 @MainActor）。
@MainActor
final class RecordingErrorPhraserTests: XCTestCase {
    /// 超时：必须给出"其他应用占用麦克风"这类可执行下一步，而不是"Recording took too long to start."。
    func testStartupTimeoutMapsToActionableChineseFriendlyMessage() {
        let message = RecordingErrorPhraser.humanMessage(for: RecordingStartupStep.StartupError.timedOut)
        XCTAssertNotNil(message)
        XCTAssertEqual(
            message,
            String(localized: "Recording took too long to start. Another app may be using the microphone. Stop it and try again.")
        )
    }

    /// 无设备：必须换成用户能看懂的提示，而不是底层描述。
    func testNoInputDeviceMapsToFriendlyMessage() {
        XCTAssertEqual(
            RecordingErrorPhraser.humanMessage(for: AudioEngineError.noInputDevice),
            String(localized: "No microphone or audio input device was found.")
        )
        XCTAssertEqual(
            RecordingErrorPhraser.humanMessage(for: SpeechError.noInputDevice),
            String(localized: "Failed to start recording. Please check the microphone and try again.")
        )
    }

    /// 识别不可用：单独一条映射，不能和"启动失败"混为一谈。
    func testRecognizerUnavailableMapsToItsOwnMessage() {
        XCTAssertEqual(
            RecordingErrorPhraser.humanMessage(for: SpeechError.recognizerUnavailable),
            String(localized: "Speech recognition is unavailable on this device.")
        )
        XCTAssertEqual(
            RecordingErrorPhraser.humanMessage(for: AudioEngineError.recognizerUnavailable),
            String(localized: "Speech recognition is unavailable on this device.")
        )
    }

    /// CancellationError 绝不能裸奔（历史事故：状态栏显示 Swift.CancellationError error 1）。
    func testCancellationErrorNeverLeaksTechnologyString() {
        let message = RecordingErrorPhraser.humanMessage(for: CancellationError())
        XCTAssertNotNil(message)
        XCTAssertFalse(message!.contains("Swift.CancellationError"))
        XCTAssertFalse(message!.contains("error 1"))
        XCTAssertEqual(
            message,
            String(localized: "The recording was stopped before it finished starting.")
        )
    }

    /// 未知错误保持克制：返回 nil，由调用方退回原描述，不要凭空编造文案。
    func testUnknownErrorReturnsNil() {
        struct WhateverError: Error {}
        XCTAssertNil(RecordingErrorPhraser.humanMessage(for: WhateverError()))
    }
}
