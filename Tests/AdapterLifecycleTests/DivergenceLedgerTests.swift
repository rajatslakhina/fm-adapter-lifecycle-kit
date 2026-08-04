import XCTest
@testable import AdapterLifecycle

final class DivergenceLedgerTests: XCTestCase {

    private let adapter = AdapterIdentifier("summariser.v3")
    private let other = AdapterIdentifier("tone.v1")

    private func entry(
        _ winner: DivergenceLedger.Entry.Winner,
        adapter: AdapterIdentifier? = nil,
        base: BaseModelVersion = Fixture.base27
    ) -> DivergenceLedger.Entry {
        DivergenceLedger.Entry(
            adapter: adapter ?? self.adapter,
            task: Fixture.summarise,
            baseModel: base,
            winner: winner
        )
    }

    /// The property that keeps this from being a memory leak with a business
    /// justification. Two orders of magnitude more writes than capacity.
    func testRetainedWindowIsBoundedByCapacity() {
        var ledger = DivergenceLedger(capacity: 8)
        for _ in 0..<10_000 { ledger.record(entry(.adapter)) }
        XCTAssertEqual(ledger.count, 8)
        XCTAssertEqual(ledger.summary().sampleCount, 8)
    }

    /// A ring buffer that silently kept the *oldest* entries would also stay bounded and
    /// pass the test above, while making the online signal useless.
    func testTheRetainedWindowIsTheMostRecentEntriesNotTheFirst() {
        var ledger = DivergenceLedger(capacity: 4)
        for _ in 0..<4 { ledger.record(entry(.adapter)) }
        XCTAssertEqual(ledger.summary().adapterWins, 4)
        for _ in 0..<4 { ledger.record(entry(.base)) }
        let summary = ledger.summary()
        XCTAssertEqual(summary.baseWins, 4, "the four newest entries should have displaced the four oldest")
        XCTAssertEqual(summary.adapterWins, 0)
    }

    func testWritesKeepCyclingAfterTheBufferHasWrapped() {
        var ledger = DivergenceLedger(capacity: 3)
        for _ in 0..<3 { ledger.record(entry(.base)) }
        for _ in 0..<9 { ledger.record(entry(.adapter)) }
        XCTAssertEqual(ledger.count, 3)
        XCTAssertEqual(ledger.summary().adapterWins, 3)
        XCTAssertEqual(ledger.summary().baseWins, 0)
    }

    func testCapacityIsClampedSoTheRingArithmeticCannotDivideByZero() {
        var zero = DivergenceLedger(capacity: 0)
        XCTAssertEqual(zero.capacity, 1)
        zero.record(entry(.adapter))
        zero.record(entry(.base))
        XCTAssertEqual(zero.count, 1)
        XCTAssertEqual(zero.summary().baseWins, 1)

        var negative = DivergenceLedger(capacity: -20)
        XCTAssertEqual(negative.capacity, 1)
        negative.record(entry(.tie))
        XCTAssertEqual(negative.count, 1)
    }

    func testRegressionPercentExcludesTiesFromTheDenominator() {
        var ledger = DivergenceLedger(capacity: 100)
        for _ in 0..<3 { ledger.record(entry(.base)) }
        for _ in 0..<1 { ledger.record(entry(.adapter)) }
        for _ in 0..<96 { ledger.record(entry(.tie)) }
        let summary = ledger.summary()
        XCTAssertEqual(summary.sampleCount, 100)
        XCTAssertEqual(summary.regressionPercent, 75, "3 of 4 decided comparisons, not 3 of 100")
    }

    func testRegressionPercentIsZeroWhenNothingWasDecided() {
        var ledger = DivergenceLedger(capacity: 10)
        for _ in 0..<10 { ledger.record(entry(.tie)) }
        XCTAssertEqual(ledger.summary().regressionPercent, 0, "must not divide by zero decided comparisons")
    }

    func testSummaryCanBeScopedToOneAdapter() {
        var ledger = DivergenceLedger(capacity: 100)
        for _ in 0..<5 { ledger.record(entry(.adapter)) }
        for _ in 0..<7 { ledger.record(entry(.base, adapter: other)) }
        XCTAssertEqual(ledger.summary(for: adapter).adapterWins, 5)
        XCTAssertEqual(ledger.summary(for: adapter).baseWins, 0)
        XCTAssertEqual(ledger.summary(for: other).baseWins, 7)
        XCTAssertEqual(ledger.summary().sampleCount, 12)
    }

    /// Same reasoning as the eval gate: a comparison against the old base model is not
    /// evidence about the new one, and leaving it in the window lets stale data suppress
    /// a genuine regression signal.
    func testInvalidateDropsComparisonsTakenAgainstAnotherBaseModel() {
        var ledger = DivergenceLedger(capacity: 100)
        for _ in 0..<6 { ledger.record(entry(.adapter, base: Fixture.base27)) }
        for _ in 0..<2 { ledger.record(entry(.base, base: Fixture.base271)) }
        XCTAssertEqual(ledger.count, 8)

        ledger.invalidate(keeping: Fixture.base271)
        XCTAssertEqual(ledger.count, 2)
        XCTAssertEqual(ledger.summary().baseWins, 2)
        XCTAssertEqual(ledger.summary().adapterWins, 0)
    }

    func testTheLedgerKeepsWorkingAfterInvalidation() {
        var ledger = DivergenceLedger(capacity: 4)
        for _ in 0..<4 { ledger.record(entry(.adapter, base: Fixture.base27)) }
        ledger.invalidate(keeping: Fixture.base271)
        XCTAssertEqual(ledger.count, 0)
        for _ in 0..<6 { ledger.record(entry(.base, base: Fixture.base271)) }
        XCTAssertEqual(ledger.count, 4, "write index must have been reset into range")
        XCTAssertEqual(ledger.summary().baseWins, 4)
    }
}
