import XCTest
@testable import AdapterLifecycle

final class CoordinatorTests: XCTestCase {

    private func makeCoordinator(
        exposure: Int = 100,
        budgetMegabytes: Int = 256,
        quarantineThreshold: Int = 3,
        base: BaseModelVersion = Fixture.base27
    ) -> AdapterLifecycleCoordinator {
        AdapterLifecycleCoordinator(
            configuration: Fixture.configuration(
                exposurePercent: exposure,
                budgetMegabytes: budgetMegabytes,
                quarantineThreshold: quarantineThreshold
            ),
            installedBase: base
        )
    }

    // `XCTAssert*` takes autoclosures, which cannot contain `await`, so every actor call
    // is hoisted into a local first. These two helpers keep that from drowning the tests.
    private func serving(
        _ coordinator: AdapterLifecycleCoordinator,
        _ task: TaskIdentifier = Fixture.summarise
    ) async -> ModelSelection {
        await coordinator.selection(for: task).selection
    }

    private func state(_ coordinator: AdapterLifecycleCoordinator) async -> AdapterLifecycleCoordinator.LifecycleSnapshot {
        await coordinator.snapshot()
    }

    // MARK: - Provisioning

    func testProvisionAdmitsACompatibleAdapter() async {
        let coordinator = makeCoordinator()
        let outcome = await coordinator.provision(Fixture.descriptor("s", megabytes: 40))
        XCTAssertEqual(outcome, .installed(evicted: []))

        let snapshot = await state(coordinator)
        XCTAssertEqual(snapshot.residents.map(\.descriptor.id), [AdapterIdentifier("s")])
        XCTAssertEqual(snapshot.usedBytes, 40 * Fixture.megabyte)
    }

    func testProvisionRefusesAnAdapterTheDeviceCannotRun() async {
        let coordinator = makeCoordinator(base: Fixture.base272)
        let outcome = await coordinator.provision(Fixture.descriptor("s", window: Fixture.oneGeneration))
        guard case .rejected(.rejectedIncompatible) = outcome else { return XCTFail("got \(outcome)") }

        let snapshot = await state(coordinator)
        XCTAssertTrue(snapshot.residents.isEmpty)
    }

    func testProvisionIsIdempotent() async {
        let coordinator = makeCoordinator()
        let descriptor = Fixture.descriptor("s", megabytes: 40)
        _ = await coordinator.provision(descriptor)

        let second = await coordinator.provision(descriptor)
        XCTAssertEqual(second, .alreadyResident)

        let snapshot = await state(coordinator)
        XCTAssertEqual(snapshot.usedBytes, 40 * Fixture.megabyte)
    }

    func testAFetchFailureIsReportedRatherThanSwallowed() async {
        struct AlwaysFails: AdapterProvisioning {
            func fetch(_ descriptor: AdapterDescriptor) async throws {
                throw ProvisioningError.unreachable(locator: "https://example.invalid/a")
            }
        }
        let coordinator = AdapterLifecycleCoordinator(
            configuration: Fixture.configuration(),
            installedBase: Fixture.base27,
            provisioner: AlwaysFails()
        )
        let outcome = await coordinator.provision(Fixture.descriptor("s"))
        guard case let .fetchFailed(description) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(description.contains("unreachable"), "got \(description)")

        let snapshot = await state(coordinator)
        XCTAssertTrue(snapshot.residents.isEmpty)
    }

    // MARK: - The end-to-end story

    /// The scenario the whole package exists for, in one test: an adapter is serving
    /// happily, the OS replaces the base model, and the app quietly goes back to the
    /// stock model with a reason attached rather than shipping degraded output.
    func testAnOSUpdateTakesTheAdapterOutOfServiceWithAnExplanation() async {
        let coordinator = makeCoordinator()
        let adapter = Fixture.descriptor("summariser.v3", revision: 3, window: Fixture.oneGeneration, megabytes: 40)
        _ = await coordinator.provision(adapter)
        await coordinator.recordEval(Fixture.passingEval(for: adapter, against: Fixture.base27))

        let before = await serving(coordinator)
        XCTAssertEqual(before, .adapter(adapter.id, revision: 3))

        let report = await coordinator.baseModelDidChange(to: Fixture.base272)
        XCTAssertEqual(report.previous, Fixture.base27)
        XCTAssertEqual(report.current, Fixture.base272)
        XCTAssertEqual(report.evictedIncompatible, [adapter.id])
        XCTAssertEqual(report.evalsInvalidated, [adapter.id])

        let after = await serving(coordinator)
        XCTAssertEqual(after, .baseModel(reason: .noAdapterForTask), "it was evicted, so nothing is left to consider")

        let snapshot = await state(coordinator)
        XCTAssertEqual(snapshot.usedBytes, 0, "the unusable bytes were reclaimed")
    }

    /// The subtler half: the adapter is still *compatible* after the update, so nothing
    /// gets evicted — but its eval now describes a base model that is gone, so it stops
    /// serving until it is re-evaluated. This is the case a compatibility check alone
    /// would sail straight past.
    func testACompatibleAdapterStillStandsDownUntilItIsReEvaluated() async {
        let coordinator = makeCoordinator()
        let adapter = Fixture.descriptor(
            "summariser.v3", revision: 3,
            window: BaseModelWindow(from: Fixture.base27),   // open-ended: stays compatible
            megabytes: 40
        )
        _ = await coordinator.provision(adapter)
        await coordinator.recordEval(Fixture.passingEval(for: adapter, against: Fixture.base27))

        let before = await serving(coordinator)
        XCTAssertTrue(before.usesAdapter, "control: it serves before the update")

        let report = await coordinator.baseModelDidChange(to: Fixture.base271)
        XCTAssertTrue(report.evictedIncompatible.isEmpty, "still compatible, so nothing to evict")
        XCTAssertEqual(report.evalsInvalidated, [adapter.id])

        let stoodDown = await serving(coordinator)
        XCTAssertEqual(
            stoodDown,
            .baseModel(reason: .evalGate(.staleBaseModel(evaluatedAgainst: Fixture.base27, installed: Fixture.base271)))
        )

        // Re-evaluate against the base model that is actually on the device.
        await coordinator.recordEval(Fixture.passingEval(for: adapter, against: Fixture.base271))
        let recovered = await serving(coordinator)
        XCTAssertTrue(recovered.usesAdapter, "it comes back once it has been measured again")
    }

    // MARK: - Operator controls

    func testTheKillSwitchTakesEffectImmediately() async {
        let coordinator = makeCoordinator()
        let adapter = Fixture.descriptor("s")
        _ = await coordinator.provision(adapter)
        await coordinator.recordEval(Fixture.passingEval(for: adapter))

        let before = await serving(coordinator)
        XCTAssertTrue(before.usesAdapter)

        await coordinator.revoke(adapter.id, reason: .killSwitch("INC-4471"))
        let revoked = await serving(coordinator)
        XCTAssertEqual(revoked, .baseModel(reason: .revoked(.killSwitch("INC-4471"))))

        await coordinator.clearRevocation(adapter.id)
        let restored = await serving(coordinator)
        XCTAssertTrue(restored.usesAdapter)
    }

    func testQuarantineAccumulatesAndASuccessClearsIt() async {
        let coordinator = makeCoordinator(quarantineThreshold: 3)
        let adapter = Fixture.descriptor("s")
        _ = await coordinator.provision(adapter)
        await coordinator.recordEval(Fixture.passingEval(for: adapter))

        await coordinator.recordAdapterFailure(adapter.id)
        await coordinator.recordAdapterFailure(adapter.id)
        let underThreshold = await serving(coordinator)
        XCTAssertTrue(underThreshold.usesAdapter, "two failures is under the threshold")

        await coordinator.recordAdapterFailure(adapter.id)
        let quarantined = await serving(coordinator)
        XCTAssertEqual(quarantined, .baseModel(reason: .quarantined(consecutiveFailures: 3, threshold: 3)))

        await coordinator.recordAdapterSuccess(adapter.id)
        let cleared = await serving(coordinator)
        XCTAssertTrue(cleared.usesAdapter, "a transient failure must not become a permanent quarantine")
    }

    func testRampingExposureBringsAnInstallationIntoTheCohort() async {
        let coordinator = makeCoordinator(exposure: 5)
        let adapter = Fixture.descriptor("summariser.v3", revision: 3)
        _ = await coordinator.provision(adapter)
        await coordinator.recordEval(Fixture.passingEval(for: adapter))

        // "install-A" is bucket 18 for this adapter — see RolloutPolicyTests.
        let excluded = await serving(coordinator)
        XCTAssertEqual(excluded, .baseModel(reason: .outsideRolloutCohort(bucket: 18, exposurePercent: 5)))

        await coordinator.setExposure(percent: 50)
        let included = await serving(coordinator)
        XCTAssertTrue(included.usesAdapter)
    }

    // MARK: - Storage interaction

    func testTheServingAdapterIsPinnedSoAFetchCannotEvictIt() async {
        let coordinator = makeCoordinator(budgetMegabytes: 100)
        let incumbent = Fixture.descriptor("incumbent", revision: 2, megabytes: 60)
        _ = await coordinator.provision(incumbent)
        await coordinator.recordEval(Fixture.passingEval(for: incumbent))

        let initial = await serving(coordinator)
        XCTAssertTrue(initial.usesAdapter)

        let pinnedSnapshot = await state(coordinator)
        XCTAssertEqual(pinnedSnapshot.residents.first { $0.descriptor.id == incumbent.id }?.isPinned, true)

        let outcome = await coordinator.provision(Fixture.descriptor("newcomer", revision: 3, megabytes: 60))
        guard case .rejected(.rejectedExceedsBudget) = outcome else { return XCTFail("got \(outcome)") }

        let afterPressure = await serving(coordinator)
        XCTAssertEqual(afterPressure, .adapter(incumbent.id, revision: 2), "the model in active use survived the pressure")
    }

    func testDivergenceSamplesAreScopedToTheBaseModelTheyWereTakenAgainst() async {
        let coordinator = makeCoordinator()
        let adapter = Fixture.descriptor("s", window: BaseModelWindow(from: Fixture.base27))
        _ = await coordinator.provision(adapter)
        for _ in 0..<5 {
            await coordinator.recordComparison(adapter: adapter.id, task: Fixture.summarise, winner: .adapter)
        }
        let before = await state(coordinator)
        XCTAssertEqual(before.divergence.sampleCount, 5)

        let report = await coordinator.baseModelDidChange(to: Fixture.base271)
        XCTAssertEqual(report.divergenceSamplesDropped, 5)

        let after = await state(coordinator)
        XCTAssertEqual(after.divergence.sampleCount, 0)
    }

    func testSnapshotExplainsEveryResident() async {
        let coordinator = makeCoordinator(exposure: 100)
        let good = Fixture.descriptor("summariser.v3", revision: 3, megabytes: 20)
        let unevaluated = Fixture.descriptor("tone.v1", task: Fixture.rewriteTone, revision: 1, megabytes: 20)
        _ = await coordinator.provision(good)
        _ = await coordinator.provision(unevaluated)
        await coordinator.recordEval(Fixture.passingEval(for: good))
        await coordinator.recordAdapterFailure(unevaluated.id)

        let snapshot = await state(coordinator)
        XCTAssertEqual(snapshot.installedBase, Fixture.base27)
        XCTAssertEqual(snapshot.baseModelEpoch, 0)
        XCTAssertEqual(snapshot.budgetBytes, 256 * Fixture.megabyte)
        XCTAssertEqual(snapshot.usedBytes, 40 * Fixture.megabyte)
        XCTAssertEqual(snapshot.utilisationPercent, 15)
        XCTAssertEqual(snapshot.exposurePercent, 100)
        XCTAssertEqual(snapshot.residents.count, 2)

        let goodSummary = snapshot.residents.first { $0.descriptor.id == good.id }
        XCTAssertEqual(goodSummary?.evalVerdict.allowsAdapter, true)
        XCTAssertEqual(goodSummary?.rolloutBucket, 18)
        XCTAssertNil(goodSummary?.revocation)

        let otherSummary = snapshot.residents.first { $0.descriptor.id == unevaluated.id }
        XCTAssertEqual(otherSummary?.evalVerdict, .missing)
        XCTAssertEqual(otherSummary?.consecutiveFailures, 1)
        XCTAssertEqual(otherSummary?.rolloutBucket, 66)
    }

    func testTheEpochAdvancesOnEveryBaseModelChange() async {
        let coordinator = makeCoordinator()
        let start = await state(coordinator)
        XCTAssertEqual(start.baseModelEpoch, 0)

        await coordinator.baseModelDidChange(to: Fixture.base271)
        let afterFirst = await state(coordinator)
        XCTAssertEqual(afterFirst.baseModelEpoch, 1)

        await coordinator.baseModelDidChange(to: Fixture.base272)
        let afterSecond = await state(coordinator)
        XCTAssertEqual(afterSecond.baseModelEpoch, 2)
    }
}
