/// Why a particular adapter is not serving this request.
///
/// Every fallback to the stock model carries one of these. That is the point: "the app
/// quietly used the base model" is indistinguishable from "the app used the adapter"
/// from the outside, so the only way to operate this system is for the decision to
/// explain itself every single time.
public enum AdapterRejection: Sendable, Equatable {
    /// Nothing is installed for this task at all.
    case noAdapterForTask
    /// The device has not taken the OS update this adapter needs yet. Usually resolves
    /// itself; not an error.
    case baseModelTooOld(window: BaseModelWindow, installed: BaseModelVersion)
    /// The OS moved past the adapter's window. This is the failure the package exists
    /// for, and it needs a new build, not a retry.
    case baseModelTooNew(window: BaseModelWindow, installed: BaseModelVersion)
    /// An operator pulled it.
    case revoked(RevocationReason)
    /// The device saw it fail repeatedly and stopped trying.
    case quarantined(consecutiveFailures: Int, threshold: Int)
    /// It is not measurably better than the model you get for free.
    case evalGate(EvalVerdict)
    /// This installation is not in the rollout cohort yet.
    case outsideRolloutCohort(bucket: Int, exposurePercent: Int)
}

/// What the app should actually talk to for a request.
///
/// The app never names a model. It asks for a task and gets one of these back, which is
/// the entire reason the specialisation can be rolled out, rolled back, quarantined or
/// versioned without touching call sites.
public enum ModelSelection: Sendable, Equatable {
    case adapter(AdapterIdentifier, revision: Int)
    case baseModel(reason: AdapterRejection)

    public var usesAdapter: Bool {
        if case .adapter = self { return true }
        return false
    }

    public var adapterIdentifier: AdapterIdentifier? {
        if case let .adapter(id, _) = self { return id }
        return nil
    }
}

/// Everything the pure resolution step needs. Assembled by the coordinator; passed by
/// value so the decision is a function of its inputs and nothing else.
public struct ResolutionInput: Sendable {
    public var installedBase: BaseModelVersion
    public var installationID: String
    public var candidates: [AdapterDescriptor]
    public var evals: [AdapterIdentifier: EvalRecord]
    public var revocations: [AdapterIdentifier: RevocationReason]
    public var consecutiveFailures: [AdapterIdentifier: Int]
    public var rollout: RolloutPolicy
    public var evalGate: EvalGate
    public var quarantineThreshold: Int

    public init(
        installedBase: BaseModelVersion,
        installationID: String,
        candidates: [AdapterDescriptor],
        evals: [AdapterIdentifier: EvalRecord] = [:],
        revocations: [AdapterIdentifier: RevocationReason] = [:],
        consecutiveFailures: [AdapterIdentifier: Int] = [:],
        rollout: RolloutPolicy,
        evalGate: EvalGate,
        quarantineThreshold: Int
    ) {
        self.installedBase = installedBase
        self.installationID = installationID
        self.candidates = candidates
        self.evals = evals
        self.revocations = revocations
        self.consecutiveFailures = consecutiveFailures
        self.rollout = rollout
        self.evalGate = evalGate
        self.quarantineThreshold = Saturating.nonNegative(quarantineThreshold)
    }
}

public struct ResolutionOutcome: Sendable, Equatable {
    public struct AuditEntry: Sendable, Equatable {
        public let adapter: AdapterIdentifier
        public let revision: Int
        public let rejection: AdapterRejection
    }

    public let selection: ModelSelection
    /// Every candidate that was considered and lost, in the order they were considered.
    /// Rendered directly by the demo app, and the thing you would ship to your logging
    /// backend when someone asks why a user is not getting the specialised model.
    public let audit: [AuditEntry]
}

/// The decision itself: pure, synchronous, total.
///
/// Kept deliberately free of state, storage and I/O. The concurrency and the disk live in
/// `AdapterLifecycleCoordinator`; this is the part you want to be able to reason about,
/// so it is the part with no moving pieces.
public struct ResolutionEngine: Sendable {
    public init() {}

    public func resolve(task: TaskIdentifier, input: ResolutionInput) -> ResolutionOutcome {
        // Sorted here rather than trusting the caller, so the outcome is a function of
        // the *set* of candidates and never of the order they happened to arrive in.
        let candidates = input.candidates
            .filter { $0.task == task }
            .sorted { lhs, rhs in
                if lhs.revision != rhs.revision { return lhs.revision > rhs.revision }
                return lhs.id < rhs.id
            }

        guard !candidates.isEmpty else {
            return ResolutionOutcome(selection: .baseModel(reason: .noAdapterForTask), audit: [])
        }

        var audit: [ResolutionOutcome.AuditEntry] = []
        for descriptor in candidates {
            guard let rejection = rejection(for: descriptor, input: input) else {
                return ResolutionOutcome(
                    selection: .adapter(descriptor.id, revision: descriptor.revision),
                    audit: audit
                )
            }
            audit.append(
                ResolutionOutcome.AuditEntry(
                    adapter: descriptor.id,
                    revision: descriptor.revision,
                    rejection: rejection
                )
            )
        }

        // Everything lost. Surface the *best* candidate's reason — that is the one an
        // engineer reading a single log line needs, and `audit` still carries the rest.
        let headline = audit.first?.rejection ?? .noAdapterForTask
        return ResolutionOutcome(selection: .baseModel(reason: headline), audit: audit)
    }

    /// `nil` means the adapter is eligible.
    ///
    /// Check order is not arbitrary. An operator's kill switch outranks anything computed
    /// on the device, because it is the only control that works after the build shipped.
    /// Hard compatibility comes next — it is a fact, not a judgement. Then local evidence
    /// of harm, then quality, and the rollout ramp last, since it is the softest signal
    /// and reporting it as *the* reason would mask a real problem underneath.
    private func rejection(for descriptor: AdapterDescriptor, input: ResolutionInput) -> AdapterRejection? {
        if let reason = input.revocations[descriptor.id] {
            return .revoked(reason)
        }

        switch descriptor.compatibility.relation(to: input.installedBase) {
        case .installedTooOld:
            return .baseModelTooOld(window: descriptor.compatibility, installed: input.installedBase)
        case .installedTooNew:
            return .baseModelTooNew(window: descriptor.compatibility, installed: input.installedBase)
        case .satisfied:
            break
        }

        let failures = Saturating.nonNegative(input.consecutiveFailures[descriptor.id] ?? 0)
        if input.quarantineThreshold > 0, failures >= input.quarantineThreshold {
            return .quarantined(consecutiveFailures: failures, threshold: input.quarantineThreshold)
        }

        let verdict = input.evalGate.verdict(
            for: descriptor,
            record: input.evals[descriptor.id],
            installedBase: input.installedBase
        )
        guard verdict.allowsAdapter else { return .evalGate(verdict) }

        guard input.rollout.includes(installationID: input.installationID, adapter: descriptor.id) else {
            return .outsideRolloutCohort(
                bucket: input.rollout.bucket(installationID: input.installationID, adapter: descriptor.id),
                exposurePercent: input.rollout.exposurePercent
            )
        }

        return nil
    }
}
