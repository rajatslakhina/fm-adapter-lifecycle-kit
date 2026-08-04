import AdapterLifecycle

/// Everything the console needs to run a lifecycle scenario.
///
/// Deliberately has no default catalog baked in. The host app owns its adapters, its
/// storage budget and its eval thresholds — those are product decisions, not library
/// decisions — and passing them in is what keeps this a reusable console rather than a
/// screenshot of one particular app.
public struct AdapterConsoleConfiguration: Sendable {

    public var installationID: String
    public var initialBaseModel: BaseModelVersion
    /// Successive base model versions the "OS update" control walks through. Empty means
    /// the control is unavailable rather than crashing on an out-of-range index.
    public var osUpdateLadder: [BaseModelVersion]
    public var catalog: [AdapterDescriptor]
    /// The golden evaluation set per adapter: for each case, the right answer and what
    /// each of the two candidate models actually produced.
    ///
    /// Not a pair of pre-computed scores. `AdapterConsoleModel` runs these through
    /// `OfflineEvalRunner` and a real `TaskScorer`, so the delta the gate sees is measured
    /// at run time from the text — which means the console cannot show a number the
    /// scoring code disagrees with.
    public var evalFixtures: [AdapterIdentifier: [OfflineEvalRunner.Comparison]]
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
        evalFixtures: [AdapterIdentifier: [OfflineEvalRunner.Comparison]],
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
        self.evalFixtures = evalFixtures
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

    /// Rollout stops offered in the picker. Always includes the configured starting
    /// exposure, so the segmented control can never open with nothing selected.
    public var exposureStops: [Int] {
        Array(Set([0, 5, 25, 50, 100, min(100, max(0, initialExposurePercent))])).sorted()
    }
}
