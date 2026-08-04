import XCTest
@testable import AdapterLifecycle

final class ResolutionEngineTests: XCTestCase {

    private let engine = ResolutionEngine()

    private func input(
        candidates: [AdapterDescriptor],
        base: BaseModelVersion = Fixture.base27,
        installation: String = "install-A",
        evals: [AdapterIdentifier: EvalRecord] = [:],
        revocations: [AdapterIdentifier: RevocationReason] = [:],
        failures: [AdapterIdentifier: Int] = [:],
        exposure: Int = 100,
        quarantineThreshold: Int = 3
    ) -> ResolutionInput {
        ResolutionInput(
            installedBase: base,
            installationID: installation,
            candidates: candidates,
            evals: evals,
            revocations: revocations,
            consecutiveFailures: failures,
            rollout: RolloutPolicy(exposurePercent: exposure),
            evalGate: Fixture.permissiveGate,
            quarantineThreshold: quarantineThreshold
        )
    }

    func testWithNoCandidatesItServesTheBaseModel() {
        let outcome = engine.resolve(task: Fixture.summarise, input: input(candidates: []))
        XCTAssertEqual(outcome.selection, .baseModel(reason: .noAdapterForTask))
        XCTAssertTrue(outcome.audit.isEmpty)
    }

    func testCandidatesForOtherTasksAreNotConsidered() {
        let tone = Fixture.descriptor("tone", task: Fixture.rewriteTone)
        let outcome = engine.resolve(
            task: Fixture.summarise,
            input: input(candidates: [tone], evals: [tone.id: Fixture.passingEval(for: tone)])
        )
        XCTAssertEqual(outcome.selection, .baseModel(reason: .noAdapterForTask))
    }

    func testHighestRevisionWins() {
        let old = Fixture.descriptor("s", revision: 2)
        let new = Fixture.descriptor("s2", revision: 5)
        let outcome = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [old, new],
            evals: [old.id: Fixture.passingEval(for: old), new.id: Fixture.passingEval(for: new)]
        ))
        XCTAssertEqual(outcome.selection, .adapter(new.id, revision: 5))
        XCTAssertTrue(outcome.audit.isEmpty, "the winner was first, so nothing was rejected")
    }

    func testTheOutcomeDoesNotDependOnTheOrderCandidatesArriveIn() {
        let a = Fixture.descriptor("a", revision: 3)
        let b = Fixture.descriptor("b", revision: 3)
        let c = Fixture.descriptor("c", revision: 9)
        let evals = [
            a.id: Fixture.passingEval(for: a),
            b.id: Fixture.passingEval(for: b),
            c.id: Fixture.passingEval(for: c),
        ]
        let orderings: [[AdapterDescriptor]] = [[a, b, c], [c, b, a], [b, c, a], [c, a, b]]
        for ordering in orderings {
            let outcome = engine.resolve(task: Fixture.summarise, input: input(candidates: ordering, evals: evals))
            XCTAssertEqual(outcome.selection, .adapter(c.id, revision: 9), "order \(ordering.map(\.id))")
        }
    }

    func testItFallsThroughToALowerRevisionWhenTheBestCandidateIsRejected() {
        let broken = Fixture.descriptor("s2", revision: 5)
        let good = Fixture.descriptor("s1", revision: 2)
        let outcome = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [broken, good],
            evals: [good.id: Fixture.passingEval(for: good)],
            revocations: [broken.id: .withdrawn("bad training run")]
        ))
        XCTAssertEqual(outcome.selection, .adapter(good.id, revision: 2))
        XCTAssertEqual(outcome.audit.count, 1)
        XCTAssertEqual(outcome.audit.first?.adapter, broken.id)
    }

    // MARK: - Rejection reasons

    func testAnOSUpdatePastTheWindowReportsTooNew() {
        let adapter = Fixture.descriptor("s", window: Fixture.oneGeneration)
        let outcome = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [adapter], base: Fixture.base272,
            evals: [adapter.id: Fixture.passingEval(for: adapter, against: Fixture.base272)]
        ))
        guard case let .baseModel(reason) = outcome.selection,
              case let .baseModelTooNew(window, installed) = reason else {
            return XCTFail("got \(outcome.selection)")
        }
        XCTAssertEqual(window, Fixture.oneGeneration)
        XCTAssertEqual(installed, Fixture.base272)
    }

    func testADeviceThatHasNotUpdatedYetReportsTooOld() {
        let adapter = Fixture.descriptor("s", window: BaseModelWindow(from: Fixture.base271))
        let outcome = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [adapter], base: Fixture.base27,
            evals: [adapter.id: Fixture.passingEval(for: adapter)]
        ))
        guard case let .baseModel(reason) = outcome.selection, case .baseModelTooOld = reason else {
            return XCTFail("got \(outcome.selection)")
        }
    }

    /// Ordering matters: a kill switch is the only control that still works after the
    /// build shipped, so it has to outrank every locally computed reason.
    func testRevocationOutranksEveryOtherRejection() {
        let adapter = Fixture.descriptor("s", window: Fixture.oneGeneration)
        let outcome = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [adapter],
            base: Fixture.base272,                       // also incompatible
            revocations: [adapter.id: .killSwitch("INC-4471")],
            failures: [adapter.id: 99]                   // also quarantined
        ))
        guard case let .baseModel(reason) = outcome.selection,
              case let .revoked(revocation) = reason else {
            return XCTFail("got \(outcome.selection)")
        }
        XCTAssertEqual(revocation, .killSwitch("INC-4471"))
    }

    func testQuarantineTripsAtTheThresholdAndNotBefore() {
        let adapter = Fixture.descriptor("s")
        let evals = [adapter.id: Fixture.passingEval(for: adapter)]

        let below = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [adapter], evals: evals, failures: [adapter.id: 2], quarantineThreshold: 3
        ))
        XCTAssertTrue(below.selection.usesAdapter, "two failures is under the threshold")

        let at = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [adapter], evals: evals, failures: [adapter.id: 3], quarantineThreshold: 3
        ))
        XCTAssertEqual(at.selection, .baseModel(reason: .quarantined(consecutiveFailures: 3, threshold: 3)))
    }

    func testAZeroThresholdDisablesQuarantineEntirely() {
        let adapter = Fixture.descriptor("s")
        let outcome = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [adapter],
            evals: [adapter.id: Fixture.passingEval(for: adapter)],
            failures: [adapter.id: 5_000],
            quarantineThreshold: 0
        ))
        XCTAssertTrue(outcome.selection.usesAdapter)
    }

    func testAnUnevaluatedAdapterNeverServes() {
        let adapter = Fixture.descriptor("s")
        let outcome = engine.resolve(task: Fixture.summarise, input: input(candidates: [adapter]))
        XCTAssertEqual(outcome.selection, .baseModel(reason: .evalGate(.missing)))
    }

    func testStaleEvalAfterAnOSUpdateFallsBackEvenWhenTheAdapterStillFitsTheWindow() {
        // Window is open-ended, so compatibility is *not* the reason. The only thing that
        // changed is that the measurement was taken against a base model that is gone.
        let adapter = Fixture.descriptor("s", window: BaseModelWindow(from: Fixture.base27))
        let evals = [adapter.id: Fixture.passingEval(for: adapter, against: Fixture.base27)]

        let before = engine.resolve(task: Fixture.summarise, input: input(candidates: [adapter], base: Fixture.base27, evals: evals))
        XCTAssertTrue(before.selection.usesAdapter, "control: it serves before the update")

        let after = engine.resolve(task: Fixture.summarise, input: input(candidates: [adapter], base: Fixture.base271, evals: evals))
        XCTAssertEqual(
            after.selection,
            .baseModel(reason: .evalGate(.staleBaseModel(evaluatedAgainst: Fixture.base27, installed: Fixture.base271)))
        )
    }

    func testRolloutCohortIsTheLastGateAndReportsTheBucket() {
        let adapter = Fixture.descriptor("summariser.v3", revision: 3)
        let evals = [adapter.id: Fixture.passingEval(for: adapter)]
        // "install-A" hashes into bucket 18 for this adapter (see RolloutPolicyTests).
        let excluded = engine.resolve(task: Fixture.summarise, input: input(candidates: [adapter], evals: evals, exposure: 10))
        XCTAssertEqual(excluded.selection, .baseModel(reason: .outsideRolloutCohort(bucket: 18, exposurePercent: 10)))

        let included = engine.resolve(task: Fixture.summarise, input: input(candidates: [adapter], evals: evals, exposure: 25))
        XCTAssertTrue(included.selection.usesAdapter)
    }

    /// A rejection the operator can act on must not be masked by "not in the cohort yet",
    /// which is the softest signal in the chain.
    func testAHardFailureIsReportedInsteadOfTheRolloutCohort() {
        let adapter = Fixture.descriptor("summariser.v3", revision: 3, window: Fixture.oneGeneration)
        let outcome = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [adapter], base: Fixture.base272, exposure: 0
        ))
        guard case let .baseModel(reason) = outcome.selection, case .baseModelTooNew = reason else {
            return XCTFail("got \(outcome.selection) — rollout should not have masked the incompatibility")
        }
    }

    // MARK: - Audit trail

    func testEveryRejectedCandidateIsRecordedInOrder() {
        let revoked = Fixture.descriptor("c", revision: 9)
        let incompatible = Fixture.descriptor("b", revision: 7, window: BaseModelWindow(from: Fixture.base272))
        let unevaluated = Fixture.descriptor("a", revision: 5)

        let outcome = engine.resolve(task: Fixture.summarise, input: input(
            candidates: [unevaluated, incompatible, revoked],
            revocations: [revoked.id: .killSwitch("INC-1")]
        ))

        XCTAssertEqual(outcome.audit.map(\.adapter), [revoked.id, incompatible.id, unevaluated.id])
        XCTAssertEqual(outcome.audit.map(\.revision), [9, 7, 5])
        XCTAssertEqual(outcome.audit.first?.rejection, .revoked(.killSwitch("INC-1")))
        XCTAssertEqual(outcome.audit.last?.rejection, .evalGate(.missing))
        // The headline is the best candidate's reason, not the last one considered.
        XCTAssertEqual(outcome.selection, .baseModel(reason: .revoked(.killSwitch("INC-1"))))
    }
}
