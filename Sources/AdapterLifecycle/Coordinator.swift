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
        /// Ceiling on resident artifacts regardless of size. Bundled and zero-byte
        /// artifacts consume no budget, so bytes alone do not bound the resident set.
        public var maximumResidents: Int
        public var divergenceCapacity: Int

        public init(
            installationID: String,
            evalGate: EvalGate,
            rollout: RolloutPolicy,
            quarantineThreshold: Int = 3,
            storageBudgetBytes: Int,
            maximumResidents: Int = 32,
            divergenceCapacity: Int = 200
        ) {
            self.installationID = installationID
            self.evalGate = evalGate
            self.rollout = rollout
            self.quarantineThreshold = Saturating.nonNegative(quarantineThreshold)
            self.storageBudgetBytes = Saturating.nonNegative(storageBudgetBytes)
            self.maximumResidents = max(1, maximumResidents)
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
        /// Artifacts **still resident** whose eval result now describes a base model the
        /// device is no longer running. They are not deleted — see `baseModelDidChange`.
        /// Scoped to residents on purpose: naming an adapter the device does not have
        /// would put a line in the log about something the user cannot see.
        public let evalsInvalidated: [AdapterIdentifier]
        public let divergenceSamplesDropped: Int

        public init(
            previous: BaseModelVersion,
            current: BaseModelVersion,
            evictedIncompatible: [AdapterIdentifier],
            evalsInvalidated: [AdapterIdentifier],
            divergenceSamplesDropped: Int
        ) {
            self.previous = previous
            self.current = current
            self.evictedIncompatible = evictedIncompatible
            self.evalsInvalidated = evalsInvalidated
            self.divergenceSamplesDropped = divergenceSamplesDropped
        }
    }

    public struct ResidentSummary: Sendable, Equatable {
        public let descriptor: AdapterDescriptor
        public let isPinned: Bool
        public let evalVerdict: EvalVerdict
        public let revocation: RevocationReason?
        public let consecutiveFailures: Int
        public let rolloutBucket: Int

        public init(
            descriptor: AdapterDescriptor,
            isPinned: Bool,
            evalVerdict: EvalVerdict,
            revocation: RevocationReason?,
            consecutiveFailures: Int,
            rolloutBucket: Int
        ) {
            self.descriptor = descriptor
            self.isPinned = isPinned
            self.evalVerdict = evalVerdict
            self.revocation = revocation
            self.consecutiveFailures = consecutiveFailures
            self.rolloutBucket = rolloutBucket
        }
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

        public init(
            installedBase: BaseModelVersion,
            baseModelEpoch: Int,
            residents: [ResidentSummary],
            usedBytes: Int,
            budgetBytes: Int,
            utilisationPercent: Int,
            exposurePercent: Int,
            divergence: DivergenceLedger.Summary
        ) {
            self.installedBase = installedBase
            self.baseModelEpoch = baseModelEpoch
            self.residents = residents
            self.usedBytes = usedBytes
            self.budgetBytes = budgetBytes
            self.utilisationPercent = utilisationPercent
            self.exposurePercent = exposurePercent
            self.divergence = divergence
        }
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
    /// Which adapter is currently serving each task. The pin set is the union of these
    /// values, so resolving one task never unpins another task's serving adapter.
    private var servingByTask: [TaskIdentifier: AdapterIdentifier] = [:]
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
        self.storage = AdapterStorage(
            budgetBytes: configuration.storageBudgetBytes,
            maximumResidents: configuration.maximumResidents
        )
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
        case .rejectedExceedsBudget, .rejectedIncompatible, .rejectedTooManyResidents:
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
        for id in evicted { forget(id) }

        // Scoped to what is still resident. An eval for an artifact the device never
        // installed (or has just thrown away) is not something a reader can act on.
        let invalidated = evals.values
            .filter { storage.isResident($0.adapter) && $0.evaluatedAgainstBase != newVersion }
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

    public func evict(_ id: AdapterIdentifier) {
        storage.evict(id)
        forget(id)
    }

    /// Drops every trace of an adapter the device no longer has.
    ///
    /// Without this, `evals`, `revocations`, `consecutiveFailures`, `servingByTask` and the
    /// divergence window all keep entries for artifacts that were evicted months ago. Each
    /// one is small; together they are a slow leak in a process that is expected to run for
    /// weeks, keyed by an identifier space the server controls.
    private func forget(_ id: AdapterIdentifier) {
        evals.removeValue(forKey: id)
        revocations.removeValue(forKey: id)
        consecutiveFailures.removeValue(forKey: id)
        for (task, serving) in servingByTask where serving == id {
            servingByTask.removeValue(forKey: task)
        }
        divergence.forget(id)
    }

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
    /// Pins the winner so an in-flight fetch cannot evict a model currently in use, and
    /// touches it for LRU. Both are side effects of asking, which is why this lives on the
    /// actor and not on the pure engine.
    ///
    /// The pin set is the union across *all* tasks, not just this one. Pinning only the
    /// winner of the task being resolved would unpin whatever is serving every other task,
    /// which in a two-task app means asking about task B exposes task A's live adapter to
    /// eviction on the next fetch.
    @discardableResult
    public func selection(for task: TaskIdentifier) -> ResolutionOutcome {
        let outcome = engine.resolve(task: task, input: resolutionInput())
        if let id = outcome.selection.adapterIdentifier {
            servingByTask[task] = id
            storage.touch(id)
        } else {
            servingByTask.removeValue(forKey: task)
        }
        // Drop tasks whose adapter is no longer resident before taking the union, so an
        // evicted adapter cannot keep a stale pin alive.
        servingByTask = servingByTask.filter { storage.isResident($0.value) }
        storage.setPinned(exactly: Set(servingByTask.values))
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
