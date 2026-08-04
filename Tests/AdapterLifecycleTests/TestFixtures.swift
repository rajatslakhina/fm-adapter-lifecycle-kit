import Foundation
@testable import AdapterLifecycle

// Shared fixtures. Kept small and explicit — a fixture that computes what the test is
// supposed to assert is how vacuous tests get written.

enum Fixture {
    static let megabyte = 1_048_576

    static let summarise = TaskIdentifier("summarise")
    static let rewriteTone = TaskIdentifier("rewrite-tone")

    static let base27 = BaseModelVersion(27, 0, 0)
    static let base271 = BaseModelVersion(27, 1, 0)
    static let base272 = BaseModelVersion(27, 2, 0)

    /// `[27.0.0, 27.2.0)` — the common shape: valid for one base generation.
    static let oneGeneration = BaseModelWindow(from: base27, upTo: base272)

    static func descriptor(
        _ id: String,
        task: TaskIdentifier = Fixture.summarise,
        revision: Int = 1,
        window: BaseModelWindow = Fixture.oneGeneration,
        megabytes: Int = 8,
        distribution: AdapterDescriptor.Distribution = .remote(locator: "https://example.invalid/a")
    ) -> AdapterDescriptor {
        AdapterDescriptor(
            id: AdapterIdentifier(id),
            task: task,
            revision: revision,
            compatibility: window,
            payloadBytes: megabytes * megabyte,
            distribution: distribution
        )
    }

    static func passingEval(
        for descriptor: AdapterDescriptor,
        against base: BaseModelVersion = Fixture.base27,
        samples: Int = 500
    ) -> EvalRecord {
        EvalRecord(
            adapter: descriptor.id,
            adapterRevision: descriptor.revision,
            task: descriptor.task,
            evaluatedAgainstBase: base,
            adapterScore: 0.81,
            baseScore: 0.62,
            sampleCount: samples
        )
    }

    static let permissiveGate = EvalGate(minimumDelta: 0.02, minimumSampleCount: 100)

    static func configuration(
        installationID: String = "install-A",
        exposurePercent: Int = 100,
        budgetMegabytes: Int = 256,
        quarantineThreshold: Int = 3
    ) -> AdapterLifecycleCoordinator.Configuration {
        AdapterLifecycleCoordinator.Configuration(
            installationID: installationID,
            evalGate: permissiveGate,
            rollout: RolloutPolicy(exposurePercent: exposurePercent),
            quarantineThreshold: quarantineThreshold,
            storageBudgetBytes: budgetMegabytes * megabyte,
            divergenceCapacity: 64
        )
    }
}
