/// Stable identifier for an adapter artifact.
public struct AdapterIdentifier: Sendable, Hashable, Comparable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// The task an adapter specialises the base model for. Resolution is always scoped to a
/// task: an app that has specialised summarisation must not accidentally route its
/// tone-rewriting prompts through the summarisation adapter.
public struct TaskIdentifier: Sendable, Hashable, Comparable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// Everything the policy layer knows about one adapter artifact.
///
/// Note what is *not* here: no file handle, no `URL`, no session object. This package has
/// no dependency on Foundation or on the Foundation Models framework, and that is the
/// central architectural decision — see `AdapterProvisioning` for the seam. It means the
/// policy is exercised by the same tests on Linux CI as on device.
public struct AdapterDescriptor: Sendable, Hashable {
    public enum Distribution: Sendable, Hashable {
        /// Compiled into the app bundle. Always available, costs app size, cannot be
        /// evicted, and cannot be updated without shipping a build.
        case bundled
        /// Fetched at runtime from `locator`. Costs no app size, can be updated and
        /// revoked remotely, and is subject to the storage budget.
        case remote(locator: String)
    }

    public let id: AdapterIdentifier
    public let task: TaskIdentifier
    /// Monotonic revision of *this* adapter. Higher wins when several revisions of the
    /// same adapter are resident, and an eval recorded against a lower revision does not
    /// vouch for a higher one.
    public let revision: Int
    /// The base model versions this artifact was trained against and is valid for.
    public let compatibility: BaseModelWindow
    /// Size of the packaged artifact on disk. Note this is the *packaged* size, not the
    /// LoRA weights: adapter layers are single-digit megabytes but the shippable package
    /// is roughly two orders larger, which is why a storage budget exists at all.
    public let payloadBytes: Int
    public let distribution: Distribution

    public init(
        id: AdapterIdentifier,
        task: TaskIdentifier,
        revision: Int,
        compatibility: BaseModelWindow,
        payloadBytes: Int,
        distribution: Distribution
    ) {
        self.id = id
        self.task = task
        self.revision = Saturating.nonNegative(revision)
        self.compatibility = compatibility
        self.payloadBytes = Saturating.nonNegative(payloadBytes)
        self.distribution = distribution
    }

    /// Bundled adapters are exempt from the managed storage budget: they are already
    /// paid for in app size and deleting them would not free a byte.
    public var consumesManagedStorage: Bool {
        switch distribution {
        case .bundled: return false
        case .remote: return true
        }
    }
}

/// Why an adapter was pulled out of service by the operator rather than by policy.
public enum RevocationReason: Sendable, Hashable {
    /// Remote kill switch. The reason string is carried into telemetry so the on-call
    /// engineer who flipped it can be matched to the devices that honoured it.
    case killSwitch(String)
    /// Superseded by a newer revision that is already resident.
    case superseded(by: AdapterIdentifier)
    /// Withdrawn because the artifact itself is suspect (bad training run, leaked data).
    case withdrawn(String)
}
