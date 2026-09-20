import XCTest
@testable import ClassroomTranslator

final class LiveTranscriptPolicyTests: XCTestCase {
    func testCumulativeRecognitionOnlyEmitsNewSuffix() {
        XCTAssertEqual(
            RecognitionTextDelta.unseenText(
                after: "Today we are studying translation",
                in: "Today we are studying translation and speech recognition"
            ),
            "and speech recognition"
        )
    }

    func testRevisedRecognitionAnchorsOnCommittedTail() {
        XCTAssertEqual(
            RecognitionTextDelta.unseenText(
                after: "Today we discuss classroom translation",
                in: "Today we'll discuss classroom translation and accessibility"
            ),
            "and accessibility"
        )
    }

    func testRepeatedSnapshotDoesNotReplayText() {
        XCTAssertEqual(
            RecognitionTextDelta.unseenText(after: "A complete thought.", in: "A complete thought."),
            ""
        )
    }

    func testRecognizerReplayAtStartOfSuffixIsCollapsed() {
        XCTAssertEqual(
            RecognitionTextDelta.unseenText(
                after: "The lecture starts now",
                in: "The lecture starts now The lecture starts now with an example"
            ),
            "with an example"
        )
    }

    func testPunctuationRevisionDoesNotReplayCommittedWords() {
        XCTAssertEqual(
            RecognitionTextDelta.unseenText(after: "Hello.", in: "Hello, everyone in class"),
            "everyone in class"
        )
    }

    func testBoundaryCleanupPreservesNewSentenceEndingPunctuation() {
        XCTAssertEqual(
            RecognitionTextDelta.unseenText(after: "Hello.", in: "Hello, everyone in class!"),
            "everyone in class!"
        )
    }

    func testNewRecognitionContextIsNotMistakenForDuplicate() {
        XCTAssertEqual(
            RecognitionTextDelta.unseenText(after: "The first topic is complete.", in: "Now begin a new topic."),
            "Now begin a new topic."
        )
    }

    func testLegitimateRepeatInFreshContextIsPreserved() {
        XCTAssertEqual(
            RecognitionTextDelta.unseenText(after: "", in: "Please repeat after me"),
            "Please repeat after me"
        )
    }

    func testSubtitleCueUsesOnlyTrailingWords() {
        let cue = SubtitleCueBuilder.cue(
            from: "This is a deliberately long classroom sentence that should remain intact in the transcript but stay compact in the floating subtitle",
            maximumWords: 8,
            maximumCharacters: 40
        )
        XCTAssertEqual(cue, "transcript but stay compact in the floating subtitle")
    }

    func testShortSubtitleIsUnchanged() {
        XCTAssertEqual(SubtitleCueBuilder.cue(from: "A short subtitle"), "A short subtitle")
    }

    func testChineseSubtitleUsesTrailingCharacters() {
        let text = "这是一段很长的课堂字幕内容用于验证悬浮字幕只保留最后一小段方便学生快速阅读"
        XCTAssertEqual(SubtitleCueBuilder.cue(from: text, maximumWords: 12, maximumCharacters: 16), String(text.suffix(16)))
    }
}
