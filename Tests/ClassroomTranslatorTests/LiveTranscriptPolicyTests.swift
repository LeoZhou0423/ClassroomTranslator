import XCTest
@testable import ClassroomTranslator

final class LiveTranscriptPolicyTests: XCTestCase {
    func testLiveTranslationSurvivesAppendedUnfinishedSentence() {
        XCTAssertTrue(LivePartialTranslationPolicy.containsUnit("Hello students.", in: "Hello students. Today we"))
        XCTAssertFalse(LivePartialTranslationPolicy.containsUnit("Hello students.", in: "Hello teachers. Today we"))
        XCTAssertFalse(LivePartialTranslationPolicy.containsUnit("Hello students.", in: "Hello students. Next sentence."))
        XCTAssertFalse(LivePartialTranslationPolicy.containsUnit("", in: "Hello."))
    }

    func testFirstWhisperPreviewStartsBeforeRegularDecodeInterval() {
        XCTAssertTrue(WhisperDecodePolicy.shouldDecode(
            hasSpeech: true, decodeInFlight: false, bufferedSamples: 24_000,
            newSamplesSinceDecode: 24_000, silentFor: 0, hasEmittedText: false
        ))
        XCTAssertFalse(WhisperDecodePolicy.shouldDecode(
            hasSpeech: true, decodeInFlight: true, bufferedSamples: 24_000,
            newSamplesSinceDecode: 24_000, silentFor: 0, hasEmittedText: false
        ))
    }

    func testConjunctionDoesNotSplitTranslationContext() {
        XCTAssertEqual(StableSentenceUnits.split("We use data, because its structure matters."),
                       ["We use data, because its structure matters."])
    }

    func testOnlyDanglingClausesWaitForContinuation() {
        XCTAssertTrue(TranscriptContinuationPolicy.needsContinuation("During office."))
        XCTAssertTrue(TranscriptContinuationPolicy.needsContinuation("That is."))
        XCTAssertTrue(TranscriptContinuationPolicy.needsContinuation("and Auguste."))
        XCTAssertTrue(TranscriptContinuationPolicy.needsContinuation("I invite you"))
        XCTAssertFalse(TranscriptContinuationPolicy.needsContinuation("It seemed to work."))
        XCTAssertFalse(TranscriptContinuationPolicy.needsContinuation("What is death?"))
    }

    func testLectureContinuationRepairsCompoundAndInfinitive() {
        XCTAssertEqual(TranscriptContinuationPolicy.joined(
            previous: "You come talking to me during office.", incoming: "hours, you ask some question.", sameSpeaker: true, age: 3),
            "You come talking to me during office hours, you ask some question.")
        XCTAssertEqual(TranscriptContinuationPolicy.joined(
            previous: "The first thing I want to do is invite you.", incoming: "to call me Shelly.", sameSpeaker: true, age: 3),
            "The first thing I want to do is invite you to call me Shelly.")
        XCTAssertEqual(TranscriptContinuationPolicy.joined(
            previous: "That is.", incoming: "if we meet on the street.", sameSpeaker: true, age: 3),
            "That is if we meet on the street.")
    }

    func testContinuationNeverCrossesSpeakerOrLongPause() {
        XCTAssertNil(TranscriptContinuationPolicy.joined(previous: "During office.", incoming: "hours.", sameSpeaker: false, age: 2))
        XCTAssertNil(TranscriptContinuationPolicy.joined(previous: "During office.", incoming: "hours.", sameSpeaker: true, age: 16))
        XCTAssertNil(TranscriptContinuationPolicy.joined(previous: "What is death?", incoming: "to study it.", sameSpeaker: true, age: 2))
        XCTAssertNil(TranscriptContinuationPolicy.joined(previous: "It worked.", incoming: "Now I am older.", sameSpeaker: true, age: 2))
    }

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

    func testWhisperSegmentNeedsTwoConsecutiveSpeechBuffersFromSilence() {
        XCTAssertFalse(WhisperDecodePolicy.shouldOpenSegment(
            consecutiveSpeechBuffers: 1, hasSpeech: false))
        XCTAssertTrue(WhisperDecodePolicy.shouldOpenSegment(
            consecutiveSpeechBuffers: 2, hasSpeech: false))
        XCTAssertTrue(WhisperDecodePolicy.shouldOpenSegment(
            consecutiveSpeechBuffers: 3, hasSpeech: false))
    }

    func testWhisperOpenSegmentSurvivesSingleSpeechBuffer() {
        XCTAssertTrue(WhisperDecodePolicy.shouldOpenSegment(
            consecutiveSpeechBuffers: 1, hasSpeech: true))
        XCTAssertTrue(WhisperDecodePolicy.shouldOpenSegment(
            consecutiveSpeechBuffers: 0, hasSpeech: true))
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

    func testWhisperAudioWindowDoesNotGrowOnIdleSilence() {
        var window = WhisperAudioWindow(sampleRate: 100)
        for _ in 0..<20 {
            XCTAssertEqual(window.append(Array(repeating: 0, count: 10), isSpeech: false), 0)
        }
        XCTAssertEqual(window.samples.count, 30)
    }

    func testWhisperAudioWindowPreservesSpeechAndCapsTrailingSilence() {
        var window = WhisperAudioWindow(sampleRate: 100)
        _ = window.append(Array(repeating: 0, count: 30), isSpeech: false)
        XCTAssertEqual(window.append(Array(repeating: 1, count: 50), isSpeech: true), 50)
        for _ in 0..<50 {
            _ = window.append(Array(repeating: 0, count: 10), isSpeech: false)
        }
        XCTAssertEqual(window.samples.count, 180)
        XCTAssertEqual(window.samples.filter { $0 == 1 }.count, 50)
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

    func testWhisperRejectsSoundDescriptionsButKeepsSpeech() {
        for tag in ["[Music]", "(sad music).", "[Sobs]", "(Scoffs).", "\"sad noise\""] {
            XCTAssertNil(WhisperTranscriptQuality.accepted(tag), tag)
        }
        XCTAssertEqual(WhisperTranscriptQuality.accepted("[Music] What is a data structure?"),
                       "What is a data structure?")
        XCTAssertEqual(WhisperTranscriptQuality.accepted("Music helps students learn."),
                       "Music helps students learn.")
    }
}
