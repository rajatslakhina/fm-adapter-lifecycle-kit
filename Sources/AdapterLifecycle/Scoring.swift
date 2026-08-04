/// Scores one model output against a reference answer. Result is in `0...1`.
///
/// This protocol is the reason `EvalRecord` is not just two numbers a caller invented.
/// A quality gate whose inputs are unaudited magic constants is theatre; the gate is only
/// worth anything if the scores that feed it were produced by something reproducible that
/// a reviewer can run.
public protocol TaskScorer: Sendable {
    func score(candidate: String, reference: String) -> Double
}

/// Unigram-overlap F1 — the ROUGE-1 measure, computed over token bags.
///
/// Chosen deliberately over the alternatives:
///
/// - *Exact match* is useless for generative output: two correct summaries of the same
///   paragraph share almost no character sequence.
/// - *Embedding cosine similarity* is the better metric and is what a production eval
///   pipeline should use — but it needs a model, which would drag this package back onto
///   the device and undo the whole point of `AdapterProvisioning`. Swap it in by
///   conforming your own type to `TaskScorer`; nothing else changes.
/// - *Recall alone* (plain ROUGE-1 recall) rewards a model that pads its output with
///   every plausible word. F1 penalises that, which matters because a fine-tuned adapter
///   drifting toward verbosity is a real and common failure.
///
/// Bag semantics, not set semantics: a candidate that repeats "the" nine times gets credit
/// for it exactly as many times as the reference does, and no more.
public struct TokenOverlapF1Scorer: TaskScorer {
    public init() {}

    public func score(candidate: String, reference: String) -> Double {
        let candidateTokens = Self.tokenize(candidate)
        let referenceTokens = Self.tokenize(reference)

        // Both empty is a degenerate but legitimate input (an empty reference for an
        // "answer nothing" case). Scoring it 1.0 would let a silent model look perfect,
        // so it fails closed at 0.
        guard !candidateTokens.isEmpty, !referenceTokens.isEmpty else { return 0 }

        var referenceCounts: [String: Int] = [:]
        for token in referenceTokens {
            referenceCounts[token] = Saturating.add(referenceCounts[token] ?? 0, 1)
        }

        var overlap = 0
        for token in candidateTokens where (referenceCounts[token] ?? 0) > 0 {
            referenceCounts[token] = Saturating.subtract(referenceCounts[token] ?? 0, 1)
            overlap = Saturating.add(overlap, 1)
        }
        guard overlap > 0 else { return 0 }

        // Both counts are non-zero (checked above), so neither division can trap.
        let precision = Double(overlap) / Double(candidateTokens.count)
        let recall = Double(overlap) / Double(referenceTokens.count)
        let denominator = precision + recall
        guard denominator > 0, denominator.isFinite else { return 0 }

        let f1 = 2 * precision * recall / denominator
        guard f1.isFinite else { return 0 }
        return min(1, max(0, f1))
    }

    /// Lowercased alphanumeric runs. No stemming and no stop-word list on purpose: both
    /// are language-specific, and a scorer that silently behaves differently in Turkish
    /// than in English is a worse problem than a slightly blunt metric.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

/// Turns a golden evaluation set into the `EvalRecord` the gate consumes.
///
/// The important thing this type does is stamp the record with the base model version the
/// comparison was run against. That is the binding the whole package exists to enforce, and
/// making the runner the only convenient way to construct a record means the binding is
/// applied by construction rather than remembered by whoever wrote the calling code.
public struct OfflineEvalRunner: Sendable {

    /// One golden case: what the right answer looks like, and what each of the two
    /// candidate models actually produced for it.
    public struct Comparison: Sendable, Hashable {
        public let reference: String
        public let adapterOutput: String
        public let baseOutput: String

        public init(reference: String, adapterOutput: String, baseOutput: String) {
            self.reference = reference
            self.adapterOutput = adapterOutput
            self.baseOutput = baseOutput
        }
    }

    public let scorer: any TaskScorer

    public init(scorer: any TaskScorer = TokenOverlapF1Scorer()) {
        self.scorer = scorer
    }

    /// Mean score of each side over the golden set.
    ///
    /// An empty set yields zero scores and a zero sample count, which `EvalGate` rejects as
    /// `.insufficientSamples` — the adapter stands down rather than shipping on the
    /// strength of an evaluation that never ran.
    public func evaluate(
        _ comparisons: [Comparison],
        adapter: AdapterDescriptor,
        against base: BaseModelVersion
    ) -> EvalRecord {
        guard !comparisons.isEmpty else {
            return EvalRecord(
                adapter: adapter.id, adapterRevision: adapter.revision, task: adapter.task,
                evaluatedAgainstBase: base, adapterScore: 0, baseScore: 0, sampleCount: 0
            )
        }

        var adapterTotal = 0.0
        var baseTotal = 0.0
        for comparison in comparisons {
            adapterTotal += scorer.score(candidate: comparison.adapterOutput, reference: comparison.reference)
            baseTotal += scorer.score(candidate: comparison.baseOutput, reference: comparison.reference)
        }

        // `comparisons` is non-empty, so the divisor is at least 1.
        let count = Double(comparisons.count)
        return EvalRecord(
            adapter: adapter.id,
            adapterRevision: adapter.revision,
            task: adapter.task,
            evaluatedAgainstBase: base,
            adapterScore: adapterTotal / count,
            baseScore: baseTotal / count,
            sampleCount: comparisons.count
        )
    }
}
