import XCTest
@testable import AdapterLifecycle

/// A provisioner that parks inside `fetch` until the test lets it go.
///
/// This is what makes the reentrancy window observable. Without a fetch that can be held
/// open, the interleaving the coordinator guards against is timing-dependent and a test
/// for it would be a coin flip.
private actor GatedProvisioner: AdapterProvisioning {
    private var fetchArrived = false
    private var released = false
    private var parked: CheckedContinuation<Void, Never>?
    private var arrivalWatcher: CheckedContinuation<Void, Never>?

    func fetch(_ descriptor: AdapterDescriptor) async throws {
        fetchArrived = true
        arrivalWatcher?.resume()
        arrivalWatcher = nil
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parked = continuation
        }
    }

    /// Returns once `fetch` has actually been entered and parked.
    func waitUntilFetchStarted() async {
        if fetchArrived { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            arrivalWatcher = continuation
        }
    }

    func release() {
        released = true
        parked?.resume()
        parked = nil
    }
}

final class CoordinatorConcurrencyTests: XCTestCase {

    private func makeCoordinator(
        base: BaseModelVersion,
        provisioner: some AdapterProvisioning,
        budgetMegabytes: Int = 256
    ) -> AdapterLifecycleCoordinator {
        AdapterLifecycleCoordinator(
            configuration: Fixture.configuration(budgetMegabytes: budgetMegabytes),
            installedBase: base,
            provisioner: provisioner
        )
    }

    /// The bug this guards against, spelled out.
    ///
    /// `provision` checks compatibility, then awaits a fetch. An actor is reentrant across
    /// that `await`, so another task can change the base model while the fetch is in
    /// flight. The adapter here has an **open-ended** compatibility window on purpose: it
    /// is still compatible with the new base model, so re-running the compatibility check
    /// after the fetch would happily wave it through. Only the epoch comparison notices
    /// that the device configuration the decision was made against no longer exists.
    func testAnAdapterFetchedAcrossABaseModelChangeIsNotAdmitted() async {
        let gate = GatedProvisioner()
        let coordinator = makeCoordinator(base: Fixture.base27, provisioner: gate)
        let adapter = Fixture.descriptor("s", window: BaseModelWindow(from: Fixture.base27), megabytes: 20)

        async let provisioning = coordinator.provision(adapter)
        await gate.waitUntilFetchStarted()

        // Concurrent writer: the OS replaced the base model mid-download.
        await coordinator.baseModelDidChange(to: Fixture.base271)
        await gate.release()

        let outcome = await provisioning
        XCTAssertEqual(outcome, .supersededByBaseModelChange(expected: Fixture.base27, observed: Fixture.base271))

        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(
            snapshot.residents.isEmpty,
            "the artifact must not be admitted on the strength of a check made against a base model that is gone"
        )

        let selection = await coordinator.selection(for: Fixture.summarise).selection
        XCTAssertFalse(selection.usesAdapter, "and nothing may serve from it")
    }

    /// Control for the test above. Identical interleaving — the fetch is parked and
    /// released the same way — but nothing changes the base model. Without this, the test
    /// above would be consistent with "gated fetches simply never succeed."
    func testTheSameInterleavingSucceedsWhenTheBaseModelHoldsStill() async {
        let gate = GatedProvisioner()
        let coordinator = makeCoordinator(base: Fixture.base27, provisioner: gate)
        let adapter = Fixture.descriptor("s", window: BaseModelWindow(from: Fixture.base27), megabytes: 20)

        async let provisioning = coordinator.provision(adapter)
        await gate.waitUntilFetchStarted()
        await gate.release()

        let outcome = await provisioning
        XCTAssertEqual(outcome, .installed(evicted: []))

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.residents.map(\.descriptor.id), [adapter.id])
    }

    /// A base model "change" that lands on the same version still advances the epoch, so
    /// an in-flight fetch is still discarded. Comparing `installedBase` before and after
    /// the `await` — the obvious alternative to an epoch — would miss this entirely.
    func testARepeatedBaseModelVersionStillInvalidatesAnInFlightFetch() async {
        let gate = GatedProvisioner()
        let coordinator = makeCoordinator(base: Fixture.base27, provisioner: gate)
        let adapter = Fixture.descriptor("s", window: BaseModelWindow(from: Fixture.base27), megabytes: 20)

        async let provisioning = coordinator.provision(adapter)
        await gate.waitUntilFetchStarted()
        await coordinator.baseModelDidChange(to: Fixture.base27)
        await gate.release()

        let outcome = await provisioning
        XCTAssertEqual(outcome, .supersededByBaseModelChange(expected: Fixture.base27, observed: Fixture.base27))

        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.residents.isEmpty)
    }

    /// A base model change racing a *fleet* of in-flight fetches.
    ///
    /// This is the interleaving-sensitive one. Every provisioner suspends, so all forty
    /// fetches are genuinely mid-flight when the base model moves; each then resumes and
    /// either wins or is superseded depending on which side of the epoch bump it landed.
    /// The assertion is not "nothing crashed" — it is the **postcondition that must hold
    /// for every possible interleaving**: whatever the scheduler chose, no artifact that
    /// is incompatible with the final base model may be resident, and every provision must
    /// have reported one of the two legal outcomes rather than silently succeeding on a
    /// stale check.
    func testABaseModelChangeRacingManyFetchesLeavesNoIncompatibleResident() async {
        let coordinator = AdapterLifecycleCoordinator(
            configuration: Fixture.configuration(budgetMegabytes: 2_000, quarantineThreshold: 3),
            installedBase: Fixture.base27,
            provisioner: YieldingProvisioner(yields: 6)
        )
        // Valid only for the old base. If the epoch guard were removed, the ones that
        // resumed after the change would be admitted against a device that cannot run them.
        let doomed = (0..<40).map {
            Fixture.descriptor("old-\($0)", window: BaseModelWindow(from: Fixture.base27, upTo: Fixture.base271), megabytes: 5)
        }

        let outcomes = await withTaskGroup(of: AdapterLifecycleCoordinator.ProvisionOutcome.self) { group in
            for descriptor in doomed {
                group.addTask { await coordinator.provision(descriptor) }
            }
            group.addTask {
                // The concurrent writer. Yields first so it lands in the middle of the pack
                // rather than before or after all of them.
                for _ in 0..<3 { await Task.yield() }
                await coordinator.baseModelDidChange(to: Fixture.base271)
                return .alreadyResident   // sentinel, filtered out below
            }
            var collected: [AdapterLifecycleCoordinator.ProvisionOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        for outcome in outcomes {
            switch outcome {
            case .installed, .supersededByBaseModelChange, .alreadyResident, .rejected:
                continue
            case let .fetchFailed(detail):
                XCTFail("no fetch should have failed: \(detail)")
            }
        }

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.installedBase, Fixture.base271)
        for resident in snapshot.residents {
            XCTFail("nothing valid only for 27.0.0 may survive a move to 27.1.0: \(resident.descriptor.id)")
        }
        XCTAssertEqual(snapshot.usedBytes, 0)
    }

    /// Concurrent provisions racing concurrent resolutions and failure reports, under a
    /// budget too small to hold everything. Three different mutators on one actor.
    ///
    /// The postconditions are the storage invariants, and they are checked against the
    /// *final* state rather than against a predicted one — a test that predicted the exact
    /// surviving set would be asserting a scheduler order it has no right to expect.
    func testInvariantsHoldUnderMixedConcurrentMutation() async {
        let budgetMegabytes = 100
        let coordinator = AdapterLifecycleCoordinator(
            configuration: Fixture.configuration(budgetMegabytes: budgetMegabytes),
            installedBase: Fixture.base27,
            provisioner: YieldingProvisioner(yields: 3)
        )
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                let descriptor = Fixture.descriptor("adapter-\(index)", megabytes: 30)
                group.addTask {
                    _ = await coordinator.provision(descriptor)
                    await coordinator.recordEval(Fixture.passingEval(for: descriptor))
                }
                group.addTask { _ = await coordinator.selection(for: Fixture.summarise) }
                group.addTask { await coordinator.recordAdapterFailure(descriptor.id) }
            }
        }

        let snapshot = await coordinator.snapshot()
        XCTAssertLessThanOrEqual(snapshot.usedBytes, budgetMegabytes * Fixture.megabyte, "the budget was never exceeded")
        XCTAssertGreaterThanOrEqual(snapshot.usedBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.residents.count, 3, "100 MB cannot hold four 30 MB artifacts")
        // Accounting must be exactly the sum of what is actually resident — a torn
        // read-modify-write would show up here as a mismatch.
        let recomputed = snapshot.residents
            .filter(\.descriptor.consumesManagedStorage)
            .reduce(0) { $0 + $1.descriptor.payloadBytes }
        XCTAssertEqual(snapshot.usedBytes, recomputed, "usedBytes drifted from the resident set")
        // At most one adapter can be pinned for the single task involved.
        XCTAssertLessThanOrEqual(snapshot.residents.filter(\.isPinned).count, 1)
    }
}

/// A provisioner that suspends several times before returning, so a task group's fetches
/// are genuinely in flight simultaneously instead of each running to completion before the
/// next starts. `AlreadyResidentProvisioner` never suspends, which makes a "concurrency"
/// test using it byte-for-byte identical to a sequential loop.
private struct YieldingProvisioner: AdapterProvisioning {
    let yields: Int

    func fetch(_ descriptor: AdapterDescriptor) async throws {
        for _ in 0..<max(1, yields) { await Task.yield() }
    }
}
