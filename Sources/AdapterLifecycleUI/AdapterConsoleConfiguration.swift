import AdapterLifecycle

/// Everything the console needs to run a lifecycle scenario.
///
/// Deliberately has no default catalog baked in. The host app owns its adapters, its
/// storage budget and its eval thresholds — those are product decisions, not library
/// decisions — and passing them in is what keeps this a reusable console rather than a
/// screenshot of one particular app.
public struct AdapterConsoleConfiguration: Sendable {

    /// The scores an offline eval run would produce for an adapter. Held separately from
    /// `AdapterDescriptor` because an eval is a measurement taken at a moment against a
    /// specific base model, not a property of the artifact.
    public struct EvalProfile: Sendable, Hashable {
        public let adapterScore: Double
        public let baseScore: Double
        public let sampleCount: Int

        public init(adapterScore: Double, baseScore: Double, sampleCount: Int) {
            self.adapterScore = adapterScore
            self.baseScore = baseScore
            self.sampleCount = sampleCount
        }
    }

    public var installationID: String
    public var initialBaseModel: BaseModelVersion
    /// Successive base model versions the "OS update" control walks through. Empty means
    /// the control is unavailable rather than crashing on an out-of-range index.
    public var osUpdateLadder: [BaseModelVersion]
    public var catalog: [AdapterDescriptor]
    public var evalProfiles: [AdapterIdentifier: EvalProfile]
    /// Tasks offered in the picker, in display order.
    public var tasks: [TaskIdentifier]
    public var storageBudgetBytes: Int
    public var evalGate: EvalGate
    public var initialExposurePercent: Int
    public var quarantineThreshold: Int
    /// An oversized artifact used to demonstrate eviction under storage pressure.
    public var pressureCandidate: AdapterDescriptor?

    public init(
        installationID: String,
        initialBaseModel: BaseModelVersion,
        osUpdateLadder: [BaseModelVersion],
        catalog: [AdapterDescriptor],
        evalProfiles: [AdapterIdentifier: EvalProfile],
        tasks: [TaskIdentifier],
        storageBudgetBytes: Int,
        evalGate: EvalGate,
        initialExposurePercent: Int = 100,
        quarantineThreshold: Int = 3,
        pressureCandidate: AdapterDescriptor? = nil
    ) {
        self.installationID = installationID
        self.initialBaseModel = initialBaseModel
        self.osUpdateLadder = osUpdateLadder
        self.catalog = catalog
        self.evalProfiles = evalProfiles
        self.tasks = tasks
        self.storageBudgetBytes = storageBudgetBytes
        self.evalGate = evalGate
        self.initialExposurePercent = initialExposurePercent
        self.quarantineThreshold = quarantineThreshold
        self.pressureCandidate = pressureCandidate
    }

    /// The first task, or a placeholder when the host supplied none. Returning a
    /// placeholder rather than force-unwrapping means a misconfigured host gets an empty
    /// console instead of a crash on launch.
    public var primaryTask: TaskIdentifier {
        tasks.first ?? TaskIdentifier("unconfigured")
    }
}
