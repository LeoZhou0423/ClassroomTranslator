import XCTest
@testable import ClassroomTranslator

final class LiveTranscriptPolicyTests: XCTestCase {
    func testFinalTextSplitsIntoIndependentTranslationUnits() {
        XCTAssertEqual(
            StableSentenceUnits.split("First sentence. Is this second? Yes! trailing fragment"),
            ["First sentence.", "Is this second?", "Yes!", "trailing fragment"]
        )
    }

    func testDecimalPointDoesNotSplitTranslationUnit() {
        XCTAssertEqual(
            StableSentenceUnits.split("Version 3.14 works. Next"),
            ["Version 3.14 works.", "Next"]
        )
    }

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

    func testWhisperFinalCannotEraseLongerCorrectPartial() {
        let partial = "Good morning students today we will learn about photosynthesis"
        let shorterFinal = "learn about photosynthesis"
        XCTAssertEqual(
            WhisperTranscriptAccumulator.merged(previous: partial, current: shorterFinal),
            partial
        )
    }

    func testWhisperEmptyFinalCommitsExistingPartial() {
        let partial = "The mitochondria produces energy for the cell"
        XCTAssertEqual(
            WhisperTranscriptAccumulator.finalCandidate(accumulated: partial, decoded: nil),
            partial
        )
        XCTAssertEqual(
            WhisperTranscriptAccumulator.finalCandidate(accumulated: partial, decoded: "   "),
            partial
        )
    }

    func testWhisperRepeatedUtteranceRemainsInSessionHistory() {
        XCTAssertEqual(
            WhisperTranscriptAccumulator.appendingUtterance(
                "Please repeat after me",
                to: "Please repeat after me"
            ),
            "Please repeat after me Please repeat after me"
        )
    }

    func testWhisperRollingWindowsAppendOnlyUnseenTail() {
        XCTAssertEqual(
            WhisperTranscriptAccumulator.merged(
                previous: "Plants use sunlight water and carbon dioxide",
                current: "water and carbon dioxide to produce energy and oxygen"
            ),
            "Plants use sunlight water and carbon dioxide to produce energy and oxygen"
        )
    }

    func testWhisperGrowingSnapshotKeepsCorrectedLongerVersion() {
        XCTAssertEqual(
            WhisperTranscriptAccumulator.merged(
                previous: "Please write down",
                current: "Please write down the three ingredients"
            ),
            "Please write down the three ingredients"
        )
    }

    func testWhisperNeverDecodesPureSilence() {
        XCTAssertFalse(WhisperDecodePolicy.shouldDecode(
            hasSpeech: false, decodeInFlight: false,
            bufferedSamples: 160_000, newSamplesSinceDecode: 160_000,
            silentFor: 10
        ))
    }

    func testWhisperAcceptsQuietVirtualMachineSpeech() {
        XCTAssertTrue(WhisperDecodePolicy.containsSpeech(rms: 0.002))
        XCTAssertFalse(WhisperDecodePolicy.containsSpeech(rms: 0.001))
    }

    func testWhisperPartialRequiresNewAudioSincePreviousDecode() {
        XCTAssertFalse(WhisperDecodePolicy.shouldDecode(
            hasSpeech: true, decodeInFlight: false,
            bufferedSamples: 128_000, newSamplesSinceDecode: 1_024,
            silentFor: 0
        ))
        XCTAssertTrue(WhisperDecodePolicy.shouldDecode(
            hasSpeech: true, decodeInFlight: false,
            bufferedSamples: 128_000, newSamplesSinceDecode: 40_000,
            silentFor: 0
        ))
    }

    func testWhisperPauseFinalizesShortUtterance() {
        XCTAssertTrue(WhisperDecodePolicy.shouldDecode(
            hasSpeech: true, decodeInFlight: false,
            bufferedSamples: 12_000, newSamplesSinceDecode: 12_000,
            silentFor: 1.1
        ))
    }

    func testWhisperDecodeCannotFinalizeIfSpeechArrivedWhileDecoding() {
        XCTAssertFalse(WhisperDecodePolicy.shouldFinalize(
            speechRevisionAtDecodeStart: 4,
            currentSpeechRevision: 9,
            silentFor: 2
        ))
    }

    func testWhisperDecodeFinalizesOnlyStablePausedSnapshot() {
        XCTAssertTrue(WhisperDecodePolicy.shouldFinalize(
            speechRevisionAtDecodeStart: 9,
            currentSpeechRevision: 9,
            silentFor: 1.1
        ))
        XCTAssertFalse(WhisperDecodePolicy.shouldFinalize(
            speechRevisionAtDecodeStart: 9,
            currentSpeechRevision: 9,
            silentFor: 0.5
        ))
    }

    func testWhisperSchedulesFinalAfterSpeechChangedDuringSlowDecode() {
        XCTAssertTrue(WhisperDecodePolicy.shouldScheduleFollowUpFinal(
            speechRevisionAtDecodeStart: 4,
            currentSpeechRevision: 9,
            silentFor: 1.2,
            hasSpeech: true
        ))
        XCTAssertFalse(WhisperDecodePolicy.shouldScheduleFollowUpFinal(
            speechRevisionAtDecodeStart: 9,
            currentSpeechRevision: 9,
            silentFor: 1.2,
            hasSpeech: true
        ))
    }

    func testSpeechResamplerAveragesEach48kInterval() {
        XCTAssertEqual(
            AccentClassifier.resample([1, 1, 1, 3, 3, 3], from: 48_000, to: 16_000),
            [1, 3]
        )
    }

    func testWhisperRejectsDegenerateDecoderLoop() {
        XCTAssertNil(WhisperTranscriptQuality.accepted("i n i n i n i n i n i n"))
        XCTAssertEqual(
            WhisperTranscriptQuality.accepted("Today we will compare plants and animals in class"),
            "Today we will compare plants and animals in class"
        )
    }
}
