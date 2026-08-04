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

    /// Many concurrent provisions against one coordinator. The point is not throughput —
    /// it is that actor serialisation makes the accounting exact, so the byte total is the
    /// sum of what was admitted and never a torn read.
    func testConcurrentProvisionsKeepStorageAccountingExact() async {
        let coordinator = AdapterLifecycleCoordinator(
            configuration: Fixture.configuration(budgetMegabytes: 500),
            installedBase: Fixture.base27
        )
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    _ = await coordinator.provision(Fixture.descriptor("adapter-\(index)", megabytes: 10))
                }
            }
        }
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.residents.count, 40)
        XCTAssertEqual(snapshot.usedBytes, 400 * Fixture.megabyte)
        XCTAssertLessThanOrEqual(snapshot.usedBytes, snapshot.budgetBytes)
    }

    /// Under a budget that cannot hold everything, concurrency must not let the total
    /// drift above the ceiling — the invariant an unsynchronised cache breaks first.
    func testConcurrentProvisionsNeverExceedTheBudget() async {
        let coordinator = AdapterLifecycleCoordinator(
            configuration: Fixture.configuration(budgetMegabytes: 100),
            installedBase: Fixture.base27
        )
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    _ = await coordinator.provision(Fixture.descriptor("adapter-\(index)", megabytes: 30))
                }
            }
        }
        let snapshot = await coordinator.snapshot()
        XCTAssertLessThanOrEqual(snapshot.usedBytes, 100 * Fixture.megabyte)
        XCTAssertGreaterThan(snapshot.residents.count, 0, "something should have survived")
        XCTAssertLessThanOrEqual(snapshot.residents.count, 3, "100MB cannot hold four 30MB artifacts")
    }
}
