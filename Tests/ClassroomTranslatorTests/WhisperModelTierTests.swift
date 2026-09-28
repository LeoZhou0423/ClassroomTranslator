import XCTest
@testable import ClassroomTranslator

final class WhisperModelTierTests: XCTestCase {
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
