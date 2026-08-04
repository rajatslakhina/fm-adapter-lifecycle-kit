/// One offline evaluation of an adapter against the stock base model, on one task.
///
/// The load-bearing field is `evaluatedAgainstBase`. An eval result is not a property of
/// the adapter — it is a property of the *pair* (adapter revision, base model version).
/// The base model is the other half of every measurement you took, and when the OS
/// replaces it your numbers describe a system that no longer exists on the device.
/// Treating an eval as permanently valid is the single most common way this goes wrong,
/// because nothing observable breaks: the adapter still loads, still produces fluent
/// output, and quietly stops being better than the model you could have used for free.
public struct EvalRecord: Sendable, Hashable {
    public let adapter: AdapterIdentifier
    public let adapterRevision: Int
    public let task: TaskIdentifier
    public let evaluatedAgainstBase: BaseModelVersion
    public let adapterScore: Double
    public let baseScore: Double
    public let sampleCount: Int

    public init(
        adapter: AdapterIdentifier,
        adapterRevision: Int,
        task: TaskIdentifier,
        evaluatedAgainstBase: BaseModelVersion,
        adapterScore: Double,
        baseScore: Double,
        sampleCount: Int
    ) {
        self.adapter = adapter
        self.adapterRevision = Saturating.nonNegative(adapterRevision)
        self.task = task
        self.evaluatedAgainstBase = evaluatedAgainstBase
        self.adapterScore = adapterScore
        self.baseScore = baseScore
        self.sampleCount = Saturating.nonNegative(sampleCount)
    }

    /// How much better the adapter is than the base model. Not clamped and not
    /// guaranteed finite — `EvalGate` is responsible for rejecting non-finite scores.
    public var delta: Double { adapterScore - baseScore }
}

/// The verdict of the eval gate, with enough detail to explain itself in a log line.
public enum EvalVerdict: Sendable, Equatable {
    case passed(delta: Double)
    /// Measured, but not better than the base model by enough to justify the cost.
    case failedMargin(delta: Double, required: Double)
    case insufficientSamples(have: Int, required: Int)
    /// Never evaluated on this device's configuration.
    case missing
    /// Evaluated, but against a different revision of the same adapter.
    case staleRevision(evaluated: Int, installed: Int)
    /// Evaluated, but against a base model this device is no longer running.
    case staleBaseModel(evaluatedAgainst: BaseModelVersion, installed: BaseModelVersion)
    /// A score arrived as NaN or infinity — usually a divide-by-zero in whatever
    /// computed it. Fails closed rather than propagating a poisoned comparison.
    case nonFiniteScore
    /// The record belongs to a different task than the one being resolved.
    case taskMismatch(recorded: TaskIdentifier, requested: TaskIdentifier)

    public var allowsAdapter: Bool {
        if case .passed = self { return true }
        return false
    }
}

/// The rule an adapter has to clear before it is allowed to serve traffic.
///
/// This exists because "we fine-tuned it, so it must be better" is not a measurement, and
/// on a small task-specific dataset a LoRA adapter can easily come out *worse* than the
/// stock model while still looking plausible in a demo. The gate is the difference
/// between shipping a personalisation feature and shipping a regression you cannot see.
public struct EvalGate: Sendable, Hashable {
    /// How much better than base the adapter must score. Expressed in whatever units the
    /// task's scorer uses; the package does not interpret it.
    public let minimumDelta: Double
    public let minimumSampleCount: Int

    public init(minimumDelta: Double, minimumSampleCount: Int) {
        // A non-finite threshold would make every comparison below false and silently
        // disable the adapter path, which is a confusing failure. Clamp to zero instead.
        self.minimumDelta = minimumDelta.isFinite ? minimumDelta : 0
        self.minimumSampleCount = Saturating.nonNegative(minimumSampleCount)
    }

    public func verdict(
        for descriptor: AdapterDescriptor,
        record: EvalRecord?,
        installedBase: BaseModelVersion
    ) -> EvalVerdict {
        guard let record else { return .missing }
        guard record.task == descriptor.task else {
            return .taskMismatch(recorded: record.task, requested: descriptor.task)
        }
        guard record.adapterRevision == descriptor.revision else {
            return .staleRevision(evaluated: record.adapterRevision, installed: descriptor.revision)
        }
        guard record.evaluatedAgainstBase == installedBase else {
            return .staleBaseModel(evaluatedAgainst: record.evaluatedAgainstBase, installed: installedBase)
        }
        guard record.adapterScore.isFinite, record.baseScore.isFinite else {
            return .nonFiniteScore
        }
        guard record.sampleCount >= minimumSampleCount else {
            return .insufficientSamples(have: record.sampleCount, required: minimumSampleCount)
        }
        let delta = record.delta
        // `delta` is finite here: both operands were checked above and their difference
        // of two finite doubles is finite or ±infinity only on overflow, which `isFinite`
        // on the result would catch — so check it rather than assume.
        guard delta.isFinite else { return .nonFiniteScore }
        guard delta >= minimumDelta else {
            return .failedMargin(delta: delta, required: minimumDelta)
        }
        return .passed(delta: delta)
    }
}
