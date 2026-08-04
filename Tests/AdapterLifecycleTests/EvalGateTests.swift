import XCTest
@testable import AdapterLifecycle

final class EvalGateTests: XCTestCase {

    private let gate = EvalGate(minimumDelta: 0.05, minimumSampleCount: 100)
    private let descriptor = Fixture.descriptor("summariser.v3", revision: 3)

    func testPassesWhenAdapterBeatsBaseByTheRequiredMargin() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: 0.80, baseScore: 0.60, sampleCount: 400
        )
        let verdict = gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27)
        guard case let .passed(delta) = verdict else { return XCTFail("expected pass, got \(verdict)") }
        XCTAssertEqual(delta, 0.20, accuracy: 1e-9)
        XCTAssertTrue(verdict.allowsAdapter)
    }

    func testFailsWhenTheMarginIsTooThinToBeWorthIt() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: 0.62, baseScore: 0.60, sampleCount: 400
        )
        let verdict = gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27)
        guard case let .failedMargin(delta, required) = verdict else {
            return XCTFail("expected failedMargin, got \(verdict)")
        }
        XCTAssertEqual(delta, 0.02, accuracy: 1e-9)
        XCTAssertEqual(required, 0.05, accuracy: 1e-9)
        XCTAssertFalse(verdict.allowsAdapter)
    }

    func testAnAdapterThatIsWorseThanBaseIsRejected() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: 0.41, baseScore: 0.60, sampleCount: 400
        )
        XCTAssertFalse(gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27).allowsAdapter)
    }

    func testMissingRecordIsNotTreatedAsAPass() {
        XCTAssertEqual(gate.verdict(for: descriptor, record: nil, installedBase: Fixture.base27), .missing)
    }

    func testSampleCountFloorIsEnforced() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: 0.95, baseScore: 0.10, sampleCount: 4
        )
        XCTAssertEqual(
            gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27),
            .insufficientSamples(have: 4, required: 100)
        )
    }

    func testAnEvalForADifferentRevisionDoesNotVouchForThisOne() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 2, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: 0.90, baseScore: 0.60, sampleCount: 400
        )
        XCTAssertEqual(
            gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27),
            .staleRevision(evaluated: 2, installed: 3)
        )
    }

    func testAnEvalForADifferentTaskIsRejected() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: Fixture.rewriteTone,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: 0.90, baseScore: 0.60, sampleCount: 400
        )
        XCTAssertEqual(
            gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27),
            .taskMismatch(recorded: Fixture.rewriteTone, requested: Fixture.summarise)
        )
    }

    /// The central claim of the package. Same adapter, same revision, same excellent
    /// numbers — but the OS moved the base model, so the measurement describes a system
    /// that is no longer on the device and it stops counting.
    func testAnEvalTakenAgainstAnOlderBaseModelStopsCounting() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: 0.90, baseScore: 0.60, sampleCount: 400
        )
        XCTAssertTrue(gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27).allowsAdapter)
        XCTAssertEqual(
            gate.verdict(for: descriptor, record: record, installedBase: Fixture.base271),
            .staleBaseModel(evaluatedAgainst: Fixture.base27, installed: Fixture.base271)
        )
    }

    // MARK: - Mutation checks
    //
    // These exist because the tests above would all still pass against an implementation
    // that ignored `evaluatedAgainstBase` entirely — every one of them supplies a
    // matching base version in the happy path. The tests below deliberately construct the
    // broken implementation and assert it disagrees, which is the only way to show the
    // rule is actually load-bearing rather than incidentally satisfied.

    /// A gate that compares scores and nothing else — the version almost everyone writes
    /// first. It accepts precisely the record `EvalGate` refuses.
    private func naiveScoreOnlyVerdict(_ record: EvalRecord, minimumDelta: Double) -> Bool {
        record.delta >= minimumDelta
    }

    func testNaiveScoreOnlyGateAcceptsTheStaleEvalThatEvalGateRejects() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: 0.90, baseScore: 0.60, sampleCount: 400
        )
        XCTAssertTrue(
            naiveScoreOnlyVerdict(record, minimumDelta: 0.05),
            "control: the broken gate is happy with this record"
        )
        XCTAssertFalse(
            gate.verdict(for: descriptor, record: record, installedBase: Fixture.base271).allowsAdapter,
            "EvalGate must reject what the score-only gate accepts, or the base-version binding does nothing"
        )
    }

    func testNaiveScoreOnlyGateAcceptsAStaleRevisionThatEvalGateRejects() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 1, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: 0.90, baseScore: 0.60, sampleCount: 400
        )
        XCTAssertTrue(naiveScoreOnlyVerdict(record, minimumDelta: 0.05))
        XCTAssertFalse(gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27).allowsAdapter)
    }

    // MARK: - Non-finite arithmetic

    func testNaNScoresFailClosedRatherThanPropagating() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: .nan, baseScore: 0.60, sampleCount: 400
        )
        XCTAssertEqual(gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27), .nonFiniteScore)
    }

    func testInfiniteScoresFailClosed() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: .infinity, baseScore: 0.60, sampleCount: 400
        )
        XCTAssertEqual(gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27), .nonFiniteScore)
    }

    /// Both operands finite, difference infinite. Catching this needs a check on the
    /// *result*, not just on the inputs.
    func testASubtractionThatOverflowsToInfinityFailsClosed() {
        let record = EvalRecord(
            adapter: descriptor.id, adapterRevision: 3, task: descriptor.task,
            evaluatedAgainstBase: Fixture.base27,
            adapterScore: .greatestFiniteMagnitude, baseScore: -.greatestFiniteMagnitude, sampleCount: 400
        )
        XCTAssertTrue(record.adapterScore.isFinite)
        XCTAssertTrue(record.baseScore.isFinite)
        XCTAssertFalse(record.delta.isFinite, "control: the difference does overflow")
        XCTAssertEqual(gate.verdict(for: descriptor, record: record, installedBase: Fixture.base27), .nonFiniteScore)
    }

    /// A non-finite threshold would make every comparison false and silently disable the
    /// adapter path everywhere, which is a very confusing bug to chase.
    func testNonFiniteThresholdIsClampedAtConstruction() {
        XCTAssertEqual(EvalGate(minimumDelta: .nan, minimumSampleCount: 1).minimumDelta, 0)
        XCTAssertEqual(EvalGate(minimumDelta: .infinity, minimumSampleCount: 1).minimumDelta, 0)
        XCTAssertEqual(EvalGate(minimumDelta: 0.05, minimumSampleCount: -9).minimumSampleCount, 0)
    }
}
