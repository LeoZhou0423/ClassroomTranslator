import XCTest
@testable import ClassroomTranslator

final class SubtitleDisplayConfigurationTests: XCTestCase {
    func testDefaultsAndStoredValues() {
        let suite = "SubtitleDisplayConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SubtitleDisplayConfiguration(defaults: defaults).maximumWords, 12)
        XCTAssertTrue(SubtitleDisplayConfiguration(defaults: defaults).showOriginal)

        defaults.set(24.0, forKey: "fontSize")
        defaults.set(0.55, forKey: "overlayOpacity")
        defaults.set(8, forKey: "subtitleMaxWords")
        defaults.set(false, forKey: "showSubtitleOriginal")
        defaults.set(false, forKey: "autoScroll")
        let configuration = SubtitleDisplayConfiguration(defaults: defaults)
        XCTAssertEqual(configuration.fontSize, 24)
        XCTAssertEqual(configuration.opacity, 0.55)
        XCTAssertEqual(configuration.maximumWords, 8)
        XCTAssertFalse(configuration.showOriginal)
        XCTAssertFalse(configuration.autoScroll)
    }
}
