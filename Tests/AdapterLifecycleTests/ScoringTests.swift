import XCTest
@testable import AdapterLifecycle

final class TokenOverlapF1ScorerTests: XCTestCase {

    private let scorer = TokenOverlapF1Scorer()

    func testIdenticalTextScoresOne() {
        XCTAssertEqual(scorer.score(candidate: "order 88213 shipped", reference: "order 88213 shipped"), 1.0, accuracy: 1e-9)
    }

    func testDisjointTextScoresZero() {
        XCTAssertEqual(scorer.score(candidate: "alpha beta gamma", reference: "delta epsilon zeta"), 0.0, accuracy: 1e-9)
    }

    func testScoringIsCaseAndPunctuationInsensitive() {
        let a = scorer.score(candidate: "Order 88213 shipped.", reference: "order 88213 shipped")
        XCTAssertEqual(a, 1.0, accuracy: 1e-9)
        let b = scorer.score(candidate: "ORDER, 88213 — SHIPPED!", reference: "order 88213 shipped")
        XCTAssertEqual(b, 1.0, accuracy: 1e-9)
    }

    /// Hand-computed. candidate = 4 tokens, reference = 2 tokens, overlap = 2.
    /// precision = 2/4 = 0.5, recall = 2/2 = 1.0, F1 = 2(0.5)(1.0)/1.5 = 0.6666…
    func testF1MatchesTheHandComputedValue() {
        XCTAssertEqual(
            scorer.score(candidate: "the quick brown fox", reference: "brown fox"),
            2.0 / 3.0,
            accuracy: 1e-9
        )
    }

    /// The property that separates F1 from plain recall, and the reason F1 was chosen:
    /// a model that pads its answer with everything plausible gets *punished*, because the
    /// extra tokens dilute precision. Recall alone would score both of these 1.0.
    func testPaddingTheAnswerLowersTheScore() {
        let tight = scorer.score(candidate: "brown fox", reference: "brown fox")
        let padded = scorer.score(
            candidate: "brown fox and also possibly several other unrelated animals nearby",
            reference: "brown fox"
        )
        XCTAssertEqual(tight, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(padded, tight)
        XCTAssertGreaterThan(padded, 0)
    }

    /// Bag semantics, not set semantics. The candidate says "the" three times; the
    /// reference says it once, so only one of them may count. A set-based implementation
    /// would score this 1.0.
    func testRepeatedTokensAreCappedByTheReferenceCount() {
        let score = scorer.score(candidate: "the the the fox", reference: "the fox")
        // overlap = 2 ("the" once, "fox" once); precision 2/4, recall 2/2 → F1 = 2/3.
        XCTAssertEqual(score, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertLessThan(score, 1.0, "set semantics would have scored this 1.0")
    }

    /// A silent model must not look perfect against a silent reference.
    func testEmptyInputsFailClosed() {
        XCTAssertEqual(scorer.score(candidate: "", reference: ""), 0)
        XCTAssertEqual(scorer.score(candidate: "", reference: "something"), 0)
        XCTAssertEqual(scorer.score(candidate: "something", reference: ""), 0)
        XCTAssertEqual(scorer.score(candidate: "   ,,, ---  ", reference: "something"), 0)
    }

    func testScoreIsAlwaysWithinTheUnitInterval() {
        let samples = [
            ("", ""), ("a", "a"), ("a b c", "c b a"), ("x", "y"),
            ("the the the the", "the"), ("one two three four five", "three"),
        ]
        for (candidate, reference) in samples {
            let score = scorer.score(candidate: candidate, reference: reference)
            XCTAssertGreaterThanOrEqual(score, 0, "\(candidate) / \(reference)")
            XCTAssertLessThanOrEqual(score, 1, "\(candidate) / \(reference)")
            XCTAssertTrue(score.isFinite)
        }
    }
}

final class OfflineEvalRunnerTests: XCTestCase {

    private let runner = OfflineEvalRunner()
    private let descriptor = Fixture.descriptor("summariser.v3", revision: 3)

    func testProducesAMeanScoreOverTheGoldenSet() {
        let comparisons = [
            OfflineEvalRunner.Comparison(reference: "brown fox", adapterOutput: "brown fox", baseOutput: "brown"),
            OfflineEvalRunner.Comparison(reference: "brown fox", adapterOutput: "brown fox", baseOutput: "brown"),
        ]
        let record = runner.evaluate(comparisons, adapter: descriptor, against: Fixture.base27)
        XCTAssertEqual(record.adapterScore, 1.0, accuracy: 1e-9)
        // candidate 1 token, reference 2, overlap 1 → precision 1, recall 0.5, F1 = 2/3.
        XCTAssertEqual(record.baseScore, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(record.sampleCount, 2)
    }

    /// The binding the whole package turns on: the runner is the only convenient way to
    /// build an `EvalRecord`, and it stamps the base version by construction rather than
    /// leaving it to whoever wrote the calling code to remember.
    func testTheRecordIsStampedWithTheBaseModelItWasRunAgainst() {
        let record = runner.evaluate(
            [OfflineEvalRunner.Comparison(reference: "a b", adapterOutput: "a b", baseOutput: "a")],
            adapter: descriptor,
            against: Fixture.base271
        )
        XCTAssertEqual(record.evaluatedAgainstBase, Fixture.base271)
        XCTAssertEqual(record.adapter, descriptor.id)
        XCTAssertEqual(record.adapterRevision, descriptor.revision)
        XCTAssertEqual(record.task, descriptor.task)
    }

    /// An eval that never ran must not become a pass. Zero samples flows into the gate as
    /// `.insufficientSamples`, so the adapter stands down.
    func testAnEmptyGoldenSetProducesARecordTheGateRejects() {
        let record = runner.evaluate([], adapter: descriptor, against: Fixture.base27)
        XCTAssertEqual(record.sampleCount, 0)
        XCTAssertEqual(record.adapterScore, 0)
        XCTAssertEqual(record.baseScore, 0)
        let verdict = Fixture.permissiveGate.verdict(for: descriptor, record: record, installedBase: Fixture.base27)
        XCTAssertFalse(verdict.allowsAdapter)
    }

    /// End to end: measured text in, gate decision out, with no hand-written scores
    /// anywhere in the path.
    func testAnAdapterThatIsGenuinelyBetterClearsTheGateAndOneThatIsNotDoesNot() {
        let gate = EvalGate(minimumDelta: 0.05, minimumSampleCount: 2)

        let clearlyBetter = [
            OfflineEvalRunner.Comparison(
                reference: "refund approved card 4471 credited 89 dollars",
                adapterOutput: "refund approved card 4471 credited 89 dollars",
                baseOutput: "some money will be returned to the account at a later date"
            ),
            OfflineEvalRunner.Comparison(
                reference: "flight 302 delayed two hours new departure 18 40",
                adapterOutput: "flight 302 delayed two hours new departure 18 40",
                baseOutput: "there is a delay affecting one of the flights today"
            ),
        ]
        let winner = runner.evaluate(clearlyBetter, adapter: descriptor, against: Fixture.base27)
        XCTAssertTrue(gate.verdict(for: descriptor, record: winner, installedBase: Fixture.base27).allowsAdapter)

        // Hand-constructed so the arithmetic is exact rather than a guess about English.
        // Forty distinct tokens; the base model gets thirty-nine of them right.
        // precision = recall = 39/40, so F1 = 0.975 and the lift is 0.025 — real, but under
        // the 0.05 the gate demands.
        let referenceTokens = (1...40).map { "t\($0)" }
        let reference = referenceTokens.joined(separator: " ")
        let almostRight = (referenceTokens.dropLast() + ["zz"]).joined(separator: " ")
        let barelyDifferent = [
            OfflineEvalRunner.Comparison(reference: reference, adapterOutput: reference, baseOutput: almostRight),
            OfflineEvalRunner.Comparison(reference: reference, adapterOutput: reference, baseOutput: almostRight),
        ]
        let marginal = runner.evaluate(barelyDifferent, adapter: descriptor, against: Fixture.base27)
        XCTAssertEqual(marginal.adapterScore, 1.0, accuracy: 1e-9)
        XCTAssertEqual(marginal.baseScore, 0.975, accuracy: 1e-9)
        XCTAssertEqual(marginal.delta, 0.025, accuracy: 1e-9)
        let verdict = gate.verdict(for: descriptor, record: marginal, installedBase: Fixture.base27)
        XCTAssertFalse(verdict.allowsAdapter, "a rounding-error improvement must not ship")
        guard case .failedMargin = verdict else {
            return XCTFail("expected failedMargin, got \(verdict)")
        }
    }

    /// A scorer that returns non-finite values must not poison the gate into accepting.
    func testANonFiniteScorerFailsClosed() {
        struct BrokenScorer: TaskScorer {
            func score(candidate: String, reference: String) -> Double { .nan }
        }
        let record = OfflineEvalRunner(scorer: BrokenScorer()).evaluate(
            [OfflineEvalRunner.Comparison(reference: "a", adapterOutput: "a", baseOutput: "b")],
            adapter: descriptor,
            against: Fixture.base27
        )
        let verdict = Fixture.permissiveGate.verdict(for: descriptor, record: record, installedBase: Fixture.base27)
        XCTAssertEqual(verdict, .nonFiniteScore)
        XCTAssertFalse(verdict.allowsAdapter)
    }
}
