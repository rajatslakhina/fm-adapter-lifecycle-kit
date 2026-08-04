import XCTest
@testable import AdapterLifecycle
@testable import AdapterLifecycleUI

/// The presentation layer is where a `Double` from an eval meets string formatting, which
/// is exactly where `Int(_:)` traps get written. These run on Linux CI with everything
/// else.
final class PresentationTests: XCTestCase {

    func testFormatsOrdinaryValuesToTwoPlaces() {
        XCTAssertEqual(LifecyclePresentation.format(0.19), "0.19")
        XCTAssertEqual(LifecyclePresentation.format(0.2), "0.20")
        XCTAssertEqual(LifecyclePresentation.format(1), "1.00")
        XCTAssertEqual(LifecyclePresentation.format(-0.07), "-0.07")
        XCTAssertEqual(LifecyclePresentation.format(0), "0.00")
    }

    func testFormattingNonFiniteScoresDoesNotTrap() {
        XCTAssertEqual(LifecyclePresentation.format(.nan), "—")
        XCTAssertEqual(LifecyclePresentation.format(.infinity), "—")
        XCTAssertEqual(LifecyclePresentation.format(-.infinity), "—")
    }

    /// `abs(Int.min)` traps, and a score large enough to saturate the conversion is the
    /// only way to reach it.
    func testFormattingAnEnormousFiniteScoreDoesNotTrap() {
        let formatted = LifecyclePresentation.format(-Double.greatestFiniteMagnitude)
        XCTAssertFalse(formatted.isEmpty)
        XCTAssertTrue(formatted.hasPrefix("-"))
    }

    func testMegabytesClampsNegativeInputs() {
        XCTAssertEqual(LifecyclePresentation.megabytes(0), "0 MB")
        XCTAssertEqual(LifecyclePresentation.megabytes(1_048_576), "1 MB")
        XCTAssertEqual(LifecyclePresentation.megabytes(-99), "0 MB")
    }

    func testEveryRejectionExplainsItself() {
        let rejections: [AdapterRejection] = [
            .noAdapterForTask,
            .baseModelTooOld(window: Fixture.oneGeneration, installed: Fixture.base27),
            .baseModelTooNew(window: Fixture.oneGeneration, installed: Fixture.base272),
            .revoked(.killSwitch("INC-1")),
            .revoked(.superseded(by: AdapterIdentifier("s2"))),
            .revoked(.withdrawn("bad run")),
            .quarantined(consecutiveFailures: 3, threshold: 3),
            .evalGate(.missing),
            .outsideRolloutCohort(bucket: 18, exposurePercent: 5),
        ]
        for rejection in rejections {
            let text = LifecyclePresentation.explain(rejection)
            XCTAssertFalse(text.isEmpty, "\(rejection) produced no explanation")
            XCTAssertFalse(text.contains("Optional("), "\(rejection) leaked an Optional into user-facing text")
        }
    }

    func testEveryVerdictExplainsItself() {
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
        for verdict in verdicts {
            XCTAssertFalse(LifecyclePresentation.explain(verdict).isEmpty, "\(verdict)")
            XCTAssertFalse(LifecyclePresentation.shortLabel(for: verdict).isEmpty, "\(verdict)")
        }
    }

    func testAConfigurationWithNoTasksDegradesInsteadOfCrashing() {
        let configuration = AdapterConsoleConfiguration(
            installationID: "install-A",
            initialBaseModel: Fixture.base27,
            osUpdateLadder: [],
            catalog: [],
            evalProfiles: [:],
            tasks: [],
            storageBudgetBytes: 0,
            evalGate: Fixture.permissiveGate
        )
        XCTAssertEqual(configuration.primaryTask, TaskIdentifier("unconfigured"))
    }
}
