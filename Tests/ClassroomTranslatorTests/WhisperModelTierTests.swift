import XCTest
@testable import ClassroomTranslator

final class WhisperModelTierTests: XCTestCase {
    func testDefaultIsSmallAndExplicitSelectionIsPreserved() {
        let name = "WhisperModelTierTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(WhisperModelTier(userDefaults: defaults), .small)
        defaults.set("base", forKey: WhisperModelTier.defaultsKey)
        XCTAssertEqual(WhisperModelTier(userDefaults: defaults), .base)
        defaults.set("tiny", forKey: WhisperModelTier.defaultsKey)
        XCTAssertEqual(WhisperModelTier(userDefaults: defaults), .tiny)
    }

    func testWhisperRuntimeRequiresBothPhysicalMachineAndMetal() {
        XCTAssertFalse(WhisperModelTier.supportsWhisperRuntime(isVirtualMachine: true, hasMetalDevice: true))
        XCTAssertFalse(WhisperModelTier.supportsWhisperRuntime(isVirtualMachine: false, hasMetalDevice: false))
        XCTAssertTrue(WhisperModelTier.supportsWhisperRuntime(isVirtualMachine: false, hasMetalDevice: true))
    }

    func testVirtualMachineAlwaysTiny() {
        XCTAssertEqual(WhisperModelTier.recommended(physicalMemoryGB: 64, isVirtualMachine: true), .tiny)
    }

    func testLowMemoryUsesTiny() {
        XCTAssertEqual(WhisperModelTier.recommended(physicalMemoryGB: 8, isVirtualMachine: false), .tiny)
        XCTAssertEqual(WhisperModelTier.recommended(physicalMemoryGB: 4, isVirtualMachine: false), .tiny)
    }

    func testMidMemoryUsesBase() {
        XCTAssertEqual(WhisperModelTier.recommended(physicalMemoryGB: 16, isVirtualMachine: false), .base)
        XCTAssertEqual(WhisperModelTier.recommended(physicalMemoryGB: 12, isVirtualMachine: false), .base)
    }

    func testHighMemoryUsesSmall() {
        XCTAssertEqual(WhisperModelTier.recommended(physicalMemoryGB: 32, isVirtualMachine: false), .small)
        XCTAssertEqual(WhisperModelTier.recommended(physicalMemoryGB: 24, isVirtualMachine: false), .small)
    }

    func testUnknownDefaultsToTiny() {
        XCTAssertEqual(WhisperModelTier.fallback, .tiny)
    }
}
