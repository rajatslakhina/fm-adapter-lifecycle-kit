/// The stateful half of the lifecycle: owns the catalog, the storage cache, the eval
/// ledger and the operator overrides, and serialises every mutation.
///
/// The division of labour is the design. `ResolutionEngine` is a pure function and holds
/// nothing; this actor holds everything and makes no decisions of its own. When something
/// goes wrong in production the question "was this a bad policy or a bad state
/// transition?" has a file you can open for each answer.
public actor AdapterLifecycleCoordinator {

    public struct Configuration: Sendable {
        /// Stable per-install identifier used for rollout bucketing. Must survive app
        /// launches and upgrades, or staged rollout becomes a random sample per launch.
        public var installationID: String
        public var evalGate: EvalGate
        public var rollout: RolloutPolicy
        /// Consecutive adapter failures before the device stops trying. Zero disables
        /// quarantine entirely.
        public var quarantineThreshold: Int
        public var storageBudgetBytes: Int
        public var divergenceCapacity: Int

        public init(
            installationID: String,
            evalGate: EvalGate,
            rollout: RolloutPolicy,
            quarantineThreshold: Int = 3,
            storageBudgetBytes: Int,
            divergenceCapacity: Int = 200
        ) {
            self.installationID = installationID
            self.evalGate = evalGate
            self.rollout = rollout
            self.quarantineThreshold = Saturating.nonNegative(quarantineThreshold)
            self.storageBudgetBytes = Saturating.nonNegative(storageBudgetBytes)
            self.divergenceCapacity = max(1, divergenceCapacity)
        }
    }

    public enum ProvisionOutcome: Sendable, Equatable {
        case installed(evicted: [AdapterIdentifier])
        case alreadyResident
        case rejected(AdapterStorage.AdmissionOutcome)
        case fetchFailed(String)
        /// The base model changed while the fetch was in flight, so the compatibility
        /// check made before suspending no longer holds. See `provision(_:)`.
        case supersededByBaseModelChange(expected: BaseModelVersion, observed: BaseModelVersion)
    }

    public struct BaseModelChangeReport: Sendable, Equatable {
        public let previous: BaseModelVersion
        public let current: BaseModelVersion
        /// Artifacts dropped from the cache because they cannot run on the new base.
        public let evictedIncompatible: [AdapterIdentifier]
        /// Artifacts still resident whose eval result now describes a base model the
        /// device is no longer running. They are not deleted — see `baseModelDidChange`.
        public let evalsInvalidated: [AdapterIdentifier]
        public let divergenceSamplesDropped: Int
    }

    public struct ResidentSummary: Sendable, Equatable {
        public let descriptor: AdapterDescriptor
        public let isPinned: Bool
        public let evalVerdict: EvalVerdict
        public let revocation: RevocationReason?
        public let consecutiveFailures: Int
        public let rolloutBucket: Int
    }

    public struct LifecycleSnapshot: Sendable, Equatable {
        public let installedBase: BaseModelVersion
        public let baseModelEpoch: Int
        public let residents: [ResidentSummary]
        public let usedBytes: Int
        public let budgetBytes: Int
        public let utilisationPercent: Int
        public let exposurePercent: Int
        public let divergence: DivergenceLedger.Summary
    }

    // MARK: - State

    private var configuration: Configuration
    private var installedBase: BaseModelVersion
    /// Bumped on every base model change. Used to detect that an in-flight async
    /// operation was reasoning about a device configuration that no longer exists.
    private var baseModelEpoch: Int = 0
    private var storage: AdapterStorage
    private var evals: [AdapterIdentifier: EvalRecord] = [:]
    private var revocations: [AdapterIdentifier: RevocationReason] = [:]
    private var consecutiveFailures: [AdapterIdentifier: Int] = [:]
    private var divergence: DivergenceLedger
    private let engine = ResolutionEngine()
    private let provisioner: any AdapterProvisioning

    public init(
        configuration: Configuration,
        installedBase: BaseModelVersion,
        provisioner: any AdapterProvisioning = AlreadyResidentProvisioner()
    ) {
        self.configuration = configuration
        self.installedBase = installedBase
        self.storage = AdapterStorage(budgetBytes: configuration.storageBudgetBytes)
        self.divergence = DivergenceLedger(capacity: configuration.divergenceCapacity)
        self.provisioner = provisioner
    }

    // MARK: - Provisioning

    /// Fetches and admits an adapter.
    ///
    /// The `await` on the fetch is a suspension point, and an actor is *reentrant* across
    /// suspension points: another task can enter this actor and call
    /// `baseModelDidChange(to:)` while this call is parked. If that happens, the
    /// compatibility check performed before the fetch is describing a device that no
    /// longer exists, and admitting the artifact on the strength of it would put an
    /// adapter built for base 27.0 into the cache of a device running 27.2.
    ///
    /// The epoch check below is the fix: state read before an `await` is re-validated
    /// after it, never assumed. `CoordinatorConcurrencyTests` drives exactly this
    /// interleaving with a fetch that is held open while the base model moves.
    public func provision(_ descriptor: AdapterDescriptor) async -> ProvisionOutcome {
        let epochAtStart = baseModelEpoch
        let baseAtStart = installedBase

        guard descriptor.compatibility.contains(baseAtStart) else {
            return .rejected(.rejectedIncompatible(window: descriptor.compatibility, installed: baseAtStart))
        }

        do {
            try await provisioner.fetch(descriptor)
        } catch {
            return .fetchFailed(String(describing: error))
        }

        guard baseModelEpoch == epochAtStart else {
            return .supersededByBaseModelChange(expected: baseAtStart, observed: installedBase)
        }

        let outcome = storage.admit(descriptor, installedBase: installedBase)
        switch outcome {
        case let .admitted(evicted):
            return .installed(evicted: evicted)
        case .alreadyResident:
            return .alreadyResident
        case .rejectedExceedsBudget, .rejectedIncompatible:
            return .rejected(outcome)
        }
    }

    // MARK: - Base model lifecycle

    /// Records that the OS replaced the base model underneath the app.
    ///
    /// Three things happen, and the third is the one teams miss. Incompatible artifacts
    /// are evicted, because they are now unusable bytes. Divergence samples taken against
    /// the old base are dropped, because they describe a different system. And eval
    /// records are reported as invalidated but deliberately **not deleted**: the gate
    /// already refuses to honour an eval taken against a different base version, so
    /// keeping the record costs nothing and lets the UI and the logs say *"stale, was
    /// measured against 27.0"* rather than the far less useful *"never evaluated"*.
    @discardableResult
    public func baseModelDidChange(to newVersion: BaseModelVersion) -> BaseModelChangeReport {
        let previous = installedBase
        installedBase = newVersion
        baseModelEpoch = Saturating.add(baseModelEpoch, 1)

        let evicted = storage.evictIncompatible(with: newVersion)
        for id in evicted { consecutiveFailures.removeValue(forKey: id) }

        let invalidated = evals.values
            .filter { $0.evaluatedAgainstBase != newVersion }
            .map(\.adapter)
            .sorted()

        let samplesBefore = divergence.count
        divergence.invalidate(keeping: newVersion)
        let dropped = Saturating.subtract(samplesBefore, divergence.count)

        return BaseModelChangeReport(
            previous: previous,
            current: newVersion,
            evictedIncompatible: evicted,
            evalsInvalidated: invalidated,
            divergenceSamplesDropped: dropped
        )
    }

    // MARK: - Operator controls

    public func recordEval(_ record: EvalRecord) { evals[record.adapter] = record }

    public func revoke(_ id: AdapterIdentifier, reason: RevocationReason) { revocations[id] = reason }

    public func clearRevocation(_ id: AdapterIdentifier) { revocations.removeValue(forKey: id) }

    public func setExposure(percent: Int) {
        configuration.rollout = RolloutPolicy(exposurePercent: percent)
    }

    public func evict(_ id: AdapterIdentifier) { storage.evict(id) }

    // MARK: - Runtime feedback

    /// An adapter failed to load or to produce a usable response.
    public func recordAdapterFailure(_ id: AdapterIdentifier) {
        consecutiveFailures[id] = Saturating.add(consecutiveFailures[id] ?? 0, 1)
    }

    /// An adapter served a request successfully. Resets the quarantine counter, so a
    /// single transient failure never accumulates into a permanent quarantine.
    public func recordAdapterSuccess(_ id: AdapterIdentifier) {
        consecutiveFailures[id] = 0
    }

    /// Records an online adapter-versus-base comparison, tagged with the base model it
    /// was taken against so it can be invalidated when that changes.
    public func recordComparison(
        adapter: AdapterIdentifier,
        task: TaskIdentifier,
        winner: DivergenceLedger.Entry.Winner
    ) {
        divergence.record(
            DivergenceLedger.Entry(adapter: adapter, task: task, baseModel: installedBase, winner: winner)
        )
    }

    // MARK: - Resolution

    /// The only question the app ever asks: what should serve this task right now?
    ///
    /// Pins the winner so an in-flight fetch cannot evict the model currently in use, and
    /// touches it for LRU. Both are side effects of asking, which is why this lives on
    /// the actor and not on the pure engine.
    @discardableResult
    public func selection(for task: TaskIdentifier) -> ResolutionOutcome {
        let outcome = engine.resolve(task: task, input: resolutionInput())
        storage.pinExclusively(outcome.selection.adapterIdentifier)
        if let id = outcome.selection.adapterIdentifier { storage.touch(id) }
        return outcome
    }

    public func snapshot() -> LifecycleSnapshot {
        let residents = storage.residentIdentifiers.compactMap { id -> ResidentSummary? in
            guard let resident = storage.resident(id) else { return nil }
            return ResidentSummary(
                descriptor: resident.descriptor,
                isPinned: resident.isPinned,
                evalVerdict: configuration.evalGate.verdict(
                    for: resident.descriptor,
                    record: evals[id],
                    installedBase: installedBase
                ),
                revocation: revocations[id],
                consecutiveFailures: Saturating.nonNegative(consecutiveFailures[id] ?? 0),
                rolloutBucket: configuration.rollout.bucket(
                    installationID: configuration.installationID,
                    adapter: id
                )
            )
        }
        return LifecycleSnapshot(
            installedBase: installedBase,
            baseModelEpoch: baseModelEpoch,
            residents: residents,
            usedBytes: storage.usedBytes,
            budgetBytes: storage.budgetBytes,
            utilisationPercent: storage.utilisationPercent,
            exposurePercent: configuration.rollout.exposurePercent,
            divergence: divergence.summary()
        )
    }

    private func resolutionInput() -> ResolutionInput {
        ResolutionInput(
            installedBase: installedBase,
            installationID: configuration.installationID,
            candidates: storage.residentIdentifiers.compactMap { storage.resident($0)?.descriptor },
            evals: evals,
            revocations: revocations,
            consecutiveFailures: consecutiveFailures,
            rollout: configuration.rollout,
            evalGate: configuration.evalGate,
            quarantineThreshold: configuration.quarantineThreshold
        )
    }
}
