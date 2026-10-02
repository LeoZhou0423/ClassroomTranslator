import XCTest
@testable import ClassroomTranslator

final class LiveUtteranceLedgerTests: XCTestCase {
    func testShortFinalCannotEraseEarlierPreviewAndRowsKeepIdentity() {
        var ledger = LiveUtteranceLedger()
        let first = ledger.ingest("We study computer science. We organize data", final: false)
        XCTAssertEqual(first.rows.count, 2)
        XCTAssertFalse(first.rows[1].isFinal)
        let final = ledger.ingest("We organize data.", final: true)
        XCTAssertEqual(final.rows.map(\.original), first.rows.map(\.original))
        XCTAssertEqual(final.rows.map(\.id), first.rows.map(\.id))
        XCTAssertTrue(final.rows.allSatisfy(\.isFinal))
    }

    func testNewSentenceDoesNotReplaceEarlierRow() {
        var ledger = LiveUtteranceLedger()
        let first = ledger.ingest("We study computer science.", final: false)
        let next = ledger.ingest("We study computer science. We organize data.", final: false)
        XCTAssertEqual(next.rows.count, 2)
        XCTAssertEqual(first.rows[0], next.rows[0])
        XCTAssertTrue(next.removedIDs.isEmpty)
    }

    func testPrematurePeriodCanAcquireContinuation() {
        var ledger = LiveUtteranceLedger()
        let first = ledger.ingest("We meet during office.", final: false)
        let next = ledger.ingest("We meet during office. hours, you ask questions.", final: true)
        XCTAssertEqual(next.rows.map(\.original), ["We meet during office hours, you ask questions."])
        XCTAssertEqual(next.rows.first?.id, first.rows.first?.id)
    }

    func testSameWordsInNextUtteranceRemainASeparateRow() {
        var ledger = LiveUtteranceLedger()
        let first = ledger.ingest("Please repeat this sentence.", final: true)
        ledger.reset()
        let next = ledger.ingest("Please repeat this sentence.", final: true)
        XCTAssertEqual(first.rows[0].original, next.rows[0].original)
        XCTAssertNotEqual(first.rows[0].id, next.rows[0].id)
    }
}
