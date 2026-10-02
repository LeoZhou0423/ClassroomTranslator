import XCTest
@testable import ClassroomTranslator

final class PunctuationTextRepairTests: XCTestCase {
    // MARK: - normalize（全角 → 半角 + 空格修复）

    func testNormalizeMapsFullWidthMarksToAscii() {
        XCTAssertEqual(PunctuationTextRepair.normalize("Hello，world。"), "Hello, world.")
        XCTAssertEqual(PunctuationTextRepair.normalize("真的吗？！"), "真的吗?!")
        XCTAssertEqual(PunctuationTextRepair.normalize("A：B；C"), "A: B; C")
    }

    func testNormalizeFixesSpaceBeforeMarkAndCommaSpacing() {
        XCTAssertEqual(PunctuationTextRepair.normalize("Kagan ,，but"), "Kagan, but")
        XCTAssertEqual(PunctuationTextRepair.normalize("fine .Next"), "fine. Next")
    }

    func testNormalizeCollapsesSpacedDoubleDash() {
        XCTAssertEqual(
            PunctuationTextRepair.normalize("immediately - - recognized"),
            "immediately -- recognized")
    }

    // MARK: - demoteFalseSentenceBoundaries（误切边界降级）

    func testDemotesPeriodBeforeLowercaseWord() {
        XCTAssertEqual(
            PunctuationTextRepair.demoteFalseSentenceBoundaries(
                "My name is Shelly Kagan. and the very first thing"),
            "My name is Shelly Kagan, and the very first thing")
    }

    func testKeepsPeriodBeforeUppercaseWord() {
        XCTAssertEqual(
            PunctuationTextRepair.demoteFalseSentenceBoundaries(
                "take a bit longer for that. It's not the name"),
            "take a bit longer for that. It's not the name")
    }

    func testKeepsDecimalPoint() {
        XCTAssertEqual(
            PunctuationTextRepair.demoteFalseSentenceBoundaries("chapter 3.5 covers death"),
            "chapter 3.5 covers death")
    }

    func testKeepsQuestionMarkAtEndOfText() {
        XCTAssertEqual(
            PunctuationTextRepair.demoteFalseSentenceBoundaries("Is there life after death?"),
            "Is there life after death?")
    }

    func testDemotesQuestionMarkBeforeLowercase() {
        XCTAssertEqual(
            PunctuationTextRepair.demoteFalseSentenceBoundaries("he asked? then we left"),
            "he asked, then we left")
    }

    // MARK: - repaired（端到端：模型原始输出 → 干净切句输入）

    /// 样本来自 Tools/sherpa/punct_prototype.py 的真实模型输出（2026-10-02）。
    func testRepairedPrototypeOutputSample1() {
        let raw = "My name is Shelly Kagan。and the very first thing I want to do is to " +
            "invite you to call me Shelly。"
        XCTAssertEqual(
            PunctuationTextRepair.repaired(raw),
            "My name is Shelly Kagan, and the very first thing I want to do is to " +
            "invite you to call me Shelly.")
    }

    func testRepairedPrototypeOutputSample3() {
        let raw = "Shelly's，the name that I respond to，I will eventually respond to " +
            "Professor Kagan ,，but the synapses take a bit longer for that。It's not " +
            "the name I immediately - - recognized。"
        XCTAssertEqual(
            PunctuationTextRepair.repaired(raw),
            "Shelly's, the name that I respond to, I will eventually respond to " +
            "Professor Kagan, but the synapses take a bit longer for that. It's not " +
            "the name I immediately -- recognized.")
    }

    /// 修复后的文本必须能被 StableSentenceUnits 切成可翻译的句子单元。
    func testRepairedTextSplitsIntoCleanSentenceUnits() {
        let repaired = PunctuationTextRepair.repaired(
            "Now the question we're going to be asking is what happens when we die。Is " +
            "there life after death。")
        XCTAssertEqual(
            StableSentenceUnits.split(repaired, includeTrailingFragment: false),
            ["Now the question we're going to be asking is what happens when we die.",
             "Is there life after death."])
    }

    func testRepairedFalseBoundaryDoesNotSplitUnit() {
        let repaired = PunctuationTextRepair.repaired(
            "My name is Shelly Kagan。and the very first thing I want to do is to invite you。")
        XCTAssertEqual(
            StableSentenceUnits.split(repaired, includeTrailingFragment: false),
            ["My name is Shelly Kagan, and the very first thing I want to do is to invite you."])
    }
}
