import XCTest
@testable import AdapterLifecycle
@testable import AdapterLifecycleUI

/// The presentation layer is where a `Double` from an eval meets string formatting, which
/// is exactly where `Int(_:)` traps get written. These run on Linux CI with everything else.
final class PresentationTests: XCTestCase {

    func testFormatsOrdinaryValuesToTwoPlaces() {
        XCTAssertEqual(LifecyclePresentation.format(0.19), "0.19")
        XCTAssertEqual(LifecyclePresentation.format(0.2), "0.20")
        XCTAssertEqual(LifecyclePresentation.format(1), "1.00")
        XCTAssertEqual(LifecyclePresentation.format(-0.07), "-0.07")
        XCTAssertEqual(LifecyclePresentation.format(0), "0.00")
        XCTAssertEqual(LifecyclePresentation.format(12.345), "12.35", "rounds, not truncates")
    }

    func testFormattingNonFiniteScoresDoesNotTrap() {
        XCTAssertEqual(LifecyclePresentation.format(.nan), "—")
        XCTAssertEqual(LifecyclePresentation.format(.infinity), "—")
        XCTAssertEqual(LifecyclePresentation.format(-.infinity), "—")
    }

    /// `abs(Int.min)` traps, and a score large enough to saturate the conversion is the
    /// only way to reach it. Asserted as an exact string rather than "not empty" — an
    /// implementation that returned a bare `"-"` would satisfy a looser check.
    func testFormattingAnEnormousFiniteScoreDoesNotTrap() {
        XCTAssertEqual(LifecyclePresentation.format(-Double.greatestFiniteMagnitude), "-92233720368547758.07")
        XCTAssertEqual(LifecyclePresentation.format(.greatestFiniteMagnitude), "92233720368547758.07")
    }

    func testMegabytesClampsNegativeInputs() {
        XCTAssertEqual(LifecyclePresentation.megabytes(0), "0 MB")
        XCTAssertEqual(LifecyclePresentation.megabytes(1_048_576), "1 MB")
        XCTAssertEqual(LifecyclePresentation.megabytes(84 * 1_048_576), "84 MB")
        XCTAssertEqual(LifecyclePresentation.megabytes(-99), "0 MB")
    }

    // MARK: - Explanations carry their payload
    //
    // Asserting only `!isEmpty` would pass against an implementation that returned the
    // literal "x" for all seventeen cases. Each assertion below names a value that only
    // the correct branch could have put in the string.

    func testRejectionExplanationsCarryTheDataAnEngineerNeeds() {
        let tooNew = LifecyclePresentation.explain(
            .baseModelTooNew(window: Fixture.oneGeneration, installed: Fixture.base272)
        )
        XCTAssertTrue(tooNew.contains("27.2.0"), tooNew)
        XCTAssertTrue(tooNew.contains("27.0.0"), "the window's lower bound: \(tooNew)")

        let tooOld = LifecyclePresentation.explain(
            .baseModelTooOld(window: Fixture.oneGeneration, installed: Fixture.base27)
        )
        XCTAssertTrue(tooOld.contains("27.0.0"), tooOld)
        XCTAssertNotEqual(tooOld, tooNew, "the two directions must not read the same")

        let quarantined = LifecyclePresentation.explain(.quarantined(consecutiveFailures: 7, threshold: 3))
        XCTAssertTrue(quarantined.contains("7"), quarantined)
        XCTAssertTrue(quarantined.contains("3"), quarantined)

        let cohort = LifecyclePresentation.explain(.outsideRolloutCohort(bucket: 18, exposurePercent: 5))
        XCTAssertTrue(cohort.contains("18"), cohort)
        XCTAssertTrue(cohort.contains("5%"), cohort)

        XCTAssertTrue(LifecyclePresentation.explain(.revoked(.killSwitch("INC-4471"))).contains("INC-4471"))
        XCTAssertTrue(LifecyclePresentation.explain(.revoked(.superseded(by: AdapterIdentifier("s2")))).contains("s2"))
        XCTAssertTrue(LifecyclePresentation.explain(.revoked(.withdrawn("bad run"))).contains("bad run"))
        XCTAssertFalse(LifecyclePresentation.explain(.noAdapterForTask).isEmpty)
    }

    func testVerdictExplanationsCarryTheirNumbers() {
        let stale = LifecyclePresentation.explain(
            .staleBaseModel(evaluatedAgainst: Fixture.base27, installed: Fixture.base271)
        )
        XCTAssertTrue(stale.contains("27.0.0"), stale)
        XCTAssertTrue(stale.contains("27.1.0"), stale)

        let margin = LifecyclePresentation.explain(.failedMargin(delta: 0.02, required: 0.05))
        XCTAssertTrue(margin.contains("0.02"), margin)
        XCTAssertTrue(margin.contains("0.05"), margin)

        XCTAssertTrue(LifecyclePresentation.explain(.passed(delta: 0.19)).contains("0.19"))
        XCTAssertTrue(LifecyclePresentation.explain(.insufficientSamples(have: 4, required: 100)).contains("100"))
        XCTAssertTrue(LifecyclePresentation.explain(.staleRevision(evaluated: 2, installed: 3)).contains("3"))
        XCTAssertTrue(LifecyclePresentation.explain(.taskMismatch(recorded: Fixture.rewriteTone, requested: Fixture.summarise))
            .contains("rewrite-tone"))
        XCTAssertFalse(LifecyclePresentation.explain(.nonFiniteScore).isEmpty)
    }

    /// Every verdict must render a *distinct* short label, or the badge in the adapter list
    /// tells the reader nothing.
    func testEveryVerdictHasItsOwnShortLabel() {
        let verdicts: [EvalVerdict] = [
            .passed(delta: 0.19),
            .failedMargin(delta: 0.01, required: 0.05),
            .insufficientSamples(have: 4, required: 100),
            .missing,
            .staleRevision(evaluated: 2, installed: 3),
            .staleBaseModel(evaluatedAgainst: Fixture.base27, installed: Fixture.base271),
            .nonFiniteScore,
            .taskMismatch(recorded: Fixture.rewriteTone, requested: Fixture.summarise),
        ]
        let labels = verdicts.map(LifecyclePresentation.shortLabel(for:))
        XCTAssertEqual(Set(labels).count, verdicts.count, "labels collide: \(labels)")
        for label in labels { XCTAssertFalse(label.isEmpty) }
    }

    func testNoExplanationLeaksASwiftDebugDescription() {
        let rejections: [AdapterRejection] = [
            .noAdapterForTask,
            .baseModelTooOld(window: Fixture.oneGeneration, installed: Fixture.base27),
            .baseModelTooNew(window: Fixture.oneGeneration, installed: Fixture.base272),
            .revoked(.killSwitch("INC-1")),
            .quarantined(consecutiveFailures: 3, threshold: 3),
            .evalGate(.missing),
            .outsideRolloutCohort(bucket: 18, exposurePercent: 5),
        ]
        for rejection in rejections {
            let text = LifecyclePresentation.explain(rejection)
            XCTAssertFalse(text.contains("Optional("), "\(rejection): \(text)")
            XCTAssertFalse(text.contains("AdapterLifecycle."), "\(rejection): \(text)")
        }
    }

    func testSelectionHeadlineDistinguishesAdapterFromBaseModel() {
        let adapter = ModelSelection.adapter(AdapterIdentifier("summariser.v3"), revision: 3)
        XCTAssertTrue(LifecyclePresentation.headline(for: adapter).contains("summariser.v3"))
        XCTAssertTrue(LifecyclePresentation.headline(for: adapter).contains("3"))
        XCTAssertEqual(LifecyclePresentation.headline(for: .baseModel(reason: .noAdapterForTask)), "Stock base model")
    }

    func testDistributionLabelsAreDistinct() {
        XCTAssertNotEqual(
            LifecyclePresentation.label(for: .bundled),
            LifecyclePresentation.label(for: .remote(locator: "https://example.invalid/a"))
        )
    }

    // MARK: - Configuration

    func testAConfigurationWithNoTasksDegradesInsteadOfCrashing() {
        let configuration = AdapterConsoleConfiguration(
            installationID: "install-A",
            initialBaseModel: Fixture.base27,
            osUpdateLadder: [],
            catalog: [],
            evalFixtures: [:],
            tasks: [],
            storageBudgetBytes: 0,
            evalGate: Fixture.permissiveGate
        )
        XCTAssertEqual(configuration.primaryTask, TaskIdentifier("unconfigured"))
    }

    /// A segmented picker whose selection is not among its tags renders with nothing
    /// selected, so the stops always have to contain the starting exposure.
    func testExposureStopsAlwaysContainTheConfiguredStartingValue() {
        for start in [0, 3, 5, 42, 100, -10, 500] {
            let configuration = AdapterConsoleConfiguration(
                installationID: "install-A",
                initialBaseModel: Fixture.base27,
                osUpdateLadder: [],
                catalog: [],
                evalFixtures: [:],
                tasks: [Fixture.summarise],
                storageBudgetBytes: 0,
                evalGate: Fixture.permissiveGate,
                initialExposurePercent: start
            )
            let clamped = min(100, max(0, start))
            XCTAssertTrue(
                configuration.exposureStops.contains(clamped),
                "stops \(configuration.exposureStops) do not contain \(clamped)"
            )
            XCTAssertEqual(configuration.exposureStops, configuration.exposureStops.sorted())
        }
    }
}
