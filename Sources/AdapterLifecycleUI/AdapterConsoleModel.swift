#if canImport(SwiftUI)
import AdapterLifecycle
import Observation

/// Drives `AdapterConsoleView`.
///
/// Every control here maps onto exactly one coordinator call — there is no shadow state
/// and no local copy of the policy. That is the point of the demo: the view can only show
/// what the library actually decided, so a screenshot of it is evidence about the library
/// rather than about the view.
@MainActor
@Observable
public final class AdapterConsoleModel {

    public struct LogLine: Identifiable, Sendable {
        public let id: Int
        public let text: String
    }

    public private(set) var snapshot: AdapterLifecycleCoordinator.LifecycleSnapshot?
    public private(set) var outcome: ResolutionOutcome?
    public private(set) var log: [LogLine] = []
    public private(set) var selectedTask: TaskIdentifier
    public private(set) var isBusy = false

    private let configuration: AdapterConsoleConfiguration
    private let coordinator: AdapterLifecycleCoordinator
    /// Real scorer, run on the fixtures at eval time. The console never displays a delta
    /// that was not computed from the text in `AdapterConsoleConfiguration.evalFixtures`.
    private let evalRunner = OfflineEvalRunner()
    private var osUpdateStep = 0
    private var nextLogID = 0
    private var pressureCandidateAdmitted = false

    /// Newest first, capped. An unbounded activity log in a long-running demo is the same
    /// bug as an unbounded telemetry buffer, just less consequential.
    private static let logLimit = 40

    public init(configuration: AdapterConsoleConfiguration) {
        self.configuration = configuration
        self.selectedTask = configuration.primaryTask
        self.coordinator = AdapterLifecycleCoordinator(
            configuration: AdapterLifecycleCoordinator.Configuration(
                installationID: configuration.installationID,
                evalGate: configuration.evalGate,
                rollout: RolloutPolicy(exposurePercent: configuration.initialExposurePercent),
                quarantineThreshold: configuration.quarantineThreshold,
                storageBudgetBytes: configuration.storageBudgetBytes,
                divergenceCapacity: 200
            ),
            installedBase: configuration.initialBaseModel
        )
    }

    public var tasks: [TaskIdentifier] { configuration.tasks }

    public var exposureStops: [Int] { configuration.exposureStops }

    public var canSimulateOSUpdate: Bool { osUpdateStep < configuration.osUpdateLadder.count }

    public var nextBaseModel: BaseModelVersion? {
        guard configuration.osUpdateLadder.indices.contains(osUpdateStep) else { return nil }
        return configuration.osUpdateLadder[osUpdateStep]
    }

    public var canFetchPressureCandidate: Bool {
        configuration.pressureCandidate != nil && !pressureCandidateAdmitted
    }

    public var pressureCandidateLabel: String {
        guard let candidate = configuration.pressureCandidate else { return "—" }
        return "\(candidate.id.rawValue) · \(LifecyclePresentation.megabytes(candidate.payloadBytes))"
    }

    // MARK: - Lifecycle

    /// Installs the catalog and records a fresh eval for each adapter against the base
    /// model the device is currently on, so the console opens in a working state rather
    /// than an empty one.
    public func start() async {
        guard snapshot == nil else { return }
        await run {
            for descriptor in self.configuration.catalog {
                let outcome = await self.coordinator.provision(descriptor)
                self.note(self.describe(outcome, for: descriptor))
            }
            await self.recordEvals(against: self.configuration.initialBaseModel)
            self.note("Evaluated every adapter against base \(self.configuration.initialBaseModel)")
        }
    }

    public func select(task: TaskIdentifier) async {
        selectedTask = task
        await run {}
    }

    // MARK: - Controls

    /// The headline interaction. Moves the base model forward exactly as an OS update
    /// would, and reports what that cost.
    public func simulateOSUpdate() async {
        guard let next = nextBaseModel else { return }
        osUpdateStep = Saturating.add(osUpdateStep, 1)
        await run {
            let report = await self.coordinator.baseModelDidChange(to: next)
            self.note("OS update: base model \(report.previous) → \(report.current)")
            if report.evictedIncompatible.isEmpty {
                self.note("No adapter was evicted — all remaining artifacts still fit their window")
            } else {
                self.note("Evicted as incompatible: \(report.evictedIncompatible.map(\.rawValue).joined(separator: ", "))")
            }
            if !report.evalsInvalidated.isEmpty {
                self.note("Evals now stale: \(report.evalsInvalidated.map(\.rawValue).joined(separator: ", "))")
            }
            if report.divergenceSamplesDropped > 0 {
                self.note("Dropped \(report.divergenceSamplesDropped) divergence samples taken against the old base")
            }
        }
    }

    /// Re-runs the offline eval against whatever base model is on the device now. This is
    /// the recovery path after an OS update: the adapter is fine, the measurement was not.
    public func reEvaluateAgainstCurrentBase() async {
        await run {
            let current = await self.coordinator.snapshot().installedBase
            await self.recordEvals(against: current)
            self.note("Re-evaluated every adapter against base \(current)")
        }
    }

    public func setExposure(percent: Int) async {
        await run {
            await self.coordinator.setExposure(percent: percent)
            self.note("Rollout exposure set to \(percent)%")
        }
    }

    public func revokeServingAdapter() async {
        guard let serving = outcome?.selection.adapterIdentifier else { return }
        await run {
            await self.coordinator.revoke(serving, reason: .killSwitch("INC-4471"))
            self.note("Kill switch pulled on \(serving.rawValue)")
        }
    }

    public func clearRevocations() async {
        await run {
            for descriptor in self.configuration.catalog {
                await self.coordinator.clearRevocation(descriptor.id)
            }
            if let candidate = self.configuration.pressureCandidate {
                await self.coordinator.clearRevocation(candidate.id)
            }
            self.note("Cleared every kill switch")
        }
    }

    public func reportFailureOnServingAdapter() async {
        guard let serving = outcome?.selection.adapterIdentifier else { return }
        await run {
            await self.coordinator.recordAdapterFailure(serving)
            await self.coordinator.recordComparison(adapter: serving, task: self.selectedTask, winner: .base)
            self.note("Recorded a failure for \(serving.rawValue)")
        }
    }

    public func reportSuccessOnServingAdapter() async {
        guard let serving = outcome?.selection.adapterIdentifier else { return }
        await run {
            await self.coordinator.recordAdapterSuccess(serving)
            await self.coordinator.recordComparison(adapter: serving, task: self.selectedTask, winner: .adapter)
            self.note("Recorded a success for \(serving.rawValue)")
        }
    }

    /// Admits an artifact big enough to force eviction, so the storage policy is visible
    /// rather than asserted.
    public func fetchPressureCandidate() async {
        guard let candidate = configuration.pressureCandidate else { return }
        await run {
            let outcome = await self.coordinator.provision(candidate)
            self.note(self.describe(outcome, for: candidate))
            if case .installed = outcome { self.pressureCandidateAdmitted = true }
            let currentBase = await self.coordinator.snapshot().installedBase
            await self.recordEvals(against: currentBase)
        }
    }

    // MARK: - Private

    /// Serialises console actions.
    ///
    /// `isBusy` is checked and set without an intervening suspension point, and the whole
    /// model is `@MainActor`, so this is a real guard rather than advisory: two overlapping
    /// actions cannot interleave across the `await`s below and land their `snapshot`
    /// assignments out of order.
    private func run(_ body: @MainActor () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        await body()
        outcome = await coordinator.selection(for: selectedTask)
        snapshot = await coordinator.snapshot()
        isBusy = false
    }

    /// Runs the golden set through `OfflineEvalRunner` and files the resulting records.
    ///
    /// The scores are computed here, not looked up. That is the difference between a demo
    /// that renders numbers someone typed into a struct and one where the gate is actually
    /// deciding on measured output.
    private func recordEvals(against base: BaseModelVersion) async {
        // Scoped to what is actually resident, not to the whole catalog. Filing an eval for
        // an artifact the device just evicted would quietly re-create the record the
        // coordinator deliberately forgot — in the app built to demonstrate that eviction
        // forgets.
        let residents = await coordinator.snapshot().residents.map(\.descriptor)
        for descriptor in residents {
            guard let comparisons = configuration.evalFixtures[descriptor.id] else { continue }
            let record = evalRunner.evaluate(comparisons, adapter: descriptor, against: base)
            await coordinator.recordEval(record)
        }
    }

    private func describe(
        _ outcome: AdapterLifecycleCoordinator.ProvisionOutcome,
        for descriptor: AdapterDescriptor
    ) -> String {
        let name = descriptor.id.rawValue
        switch outcome {
        case let .installed(evicted) where evicted.isEmpty:
            return "Installed \(name) (\(LifecyclePresentation.megabytes(descriptor.payloadBytes)))"
        case let .installed(evicted):
            return "Installed \(name), evicting \(evicted.map(\.rawValue).joined(separator: ", "))"
        case .alreadyResident:
            return "\(name) was already resident"
        case let .rejected(reason):
            switch reason {
            case let .rejectedExceedsBudget(payload, available):
                return "Refused \(name): \(LifecyclePresentation.megabytes(payload)) will not fit in \(LifecyclePresentation.megabytes(available))"
            case let .rejectedIncompatible(window, installed):
                return "Refused \(name): built for \(window), device is on \(installed)"
            case let .rejectedTooManyResidents(limit):
                return "Refused \(name): already holding the maximum of \(limit) adapters"
            case .admitted, .alreadyResident:
                return "Installed \(name)"
            }
        case let .fetchFailed(detail):
            return "Fetch failed for \(name): \(detail)"
        case let .supersededByBaseModelChange(expected, observed):
            return "Discarded \(name): base moved \(expected) → \(observed) mid-fetch"
        }
    }

    private func note(_ text: String) {
        // `Saturating.add`, not `+= 1`: the package's stated rule is that no trapping
        // arithmetic exists anywhere in it, and a counter incremented once per user action
        // is still an `Int` that a compiler will happily trap on.
        nextLogID = Saturating.add(nextLogID, 1)
        log.insert(LogLine(id: nextLogID, text: text), at: 0)
        if log.count > Self.logLimit { log.removeLast(log.count - Self.logLimit) }
    }
}
#endif
