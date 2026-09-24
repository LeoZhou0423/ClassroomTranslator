import XCTest
@testable import ClassroomTranslator

@MainActor
final class AccentClassifierTests: XCTestCase {
    func testAccentMappingUsesSupportedSpeechLocales() {
        let expected: [String: String] = [
            "england": "en-GB",
            "scotland": "en-GB",
            "wales": "en-GB",
            "us": "en-US",
            "canada": "en-CA",
            "australia": "en-AU",
            "indian": "en-IN",
            "ireland": "en-IE",
            "african": "en-ZA",
            "southatlandtic": "en-ZA",
            "malaysia": "en-GB",
            "singapore": "en-GB",
            "hongkong": "en-GB",
            "bermuda": "en-US",
            "philippines": "en-US",
            "newzealand": "en-NZ",
        ]

        for (accent, locale) in expected {
            XCTAssertEqual(AccentClassifier.locale(forAccent: accent), locale)
            XCTAssertTrue(SpeechManager.allEnglishLocales.contains(locale))
        }
    }

    func testUnknownAccentFallsBackToUKEnglish() {
        XCTAssertEqual(AccentClassifier.locale(forAccent: "unknown"), "en-GB")
    }

    func testAutomaticEnglishStartsWithUKEnglish() {
        XCTAssertEqual(SpeechManager.safeAutomaticEnglishLocale(), "en-GB")
    }
}
