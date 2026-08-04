import AdapterLifecycle

/// Turns lifecycle values into strings a human can act on.
///
/// Not guarded behind `canImport(SwiftUI)` on purpose: this is the part of the UI layer
/// with actual logic in it, so it compiles and is type-checked on Linux CI alongside the
/// core, rather than only on a machine with a simulator.
public enum LifecyclePresentation {

    public static func megabytes(_ bytes: Int) -> String {
        // Divisor is a nonzero literal, so this cannot trap.
        "\(Saturating.nonNegative(bytes) / 1_048_576) MB"
    }

    public static func headline(for selection: ModelSelection) -> String {
        switch selection {
        case let .adapter(id, revision):
            return "\(id.rawValue) · rev \(revision)"
        case .baseModel:
            return "Stock base model"
        }
    }

    public static func subtitle(for selection: ModelSelection) -> String {
        switch selection {
        case .adapter:
            return "Specialised adapter is serving this task"
        case let .baseModel(reason):
            return explain(reason)
        }
    }

    public static func explain(_ rejection: AdapterRejection) -> String {
        switch rejection {
        case .noAdapterForTask:
            return "No adapter is installed for this task"
        case let .baseModelTooOld(window, installed):
            return "Needs base \(window), device is on \(installed) — waiting for the OS update"
        case let .baseModelTooNew(window, installed):
            return "Built for base \(window), device moved to \(installed) — needs a new adapter build"
        case let .revoked(reason):
            return explain(reason)
        case let .quarantined(failures, threshold):
            return "Quarantined after \(failures) consecutive failures (limit \(threshold))"
        case let .evalGate(verdict):
            return explain(verdict)
        case let .outsideRolloutCohort(bucket, exposure):
            return "Not in the rollout cohort yet — bucket \(bucket), exposure \(exposure)%"
        }
    }

    public static func explain(_ reason: RevocationReason) -> String {
        switch reason {
        case let .killSwitch(detail):
            return "Pulled by kill switch (\(detail))"
        case let .superseded(by):
            return "Superseded by \(by.rawValue)"
        case let .withdrawn(detail):
            return "Withdrawn (\(detail))"
        }
    }

    public static func explain(_ verdict: EvalVerdict) -> String {
        switch verdict {
        case let .passed(delta):
            return "Beats base by \(format(delta))"
        case let .failedMargin(delta, required):
            return "Only \(format(delta)) better than base, needs \(format(required))"
        case let .insufficientSamples(have, required):
            return "Evaluated on \(have) samples, needs \(required)"
        case .missing:
            return "Never evaluated against this base model"
        case let .staleRevision(evaluated, installed):
            return "Eval covers rev \(evaluated), installed is rev \(installed)"
        case let .staleBaseModel(evaluatedAgainst, installed):
            return "Eval was measured against base \(evaluatedAgainst), device is on \(installed)"
        case .nonFiniteScore:
            return "Eval produced a non-finite score"
        case let .taskMismatch(recorded, requested):
            return "Eval is for \(recorded), not \(requested)"
        }
    }

    public static func shortLabel(for verdict: EvalVerdict) -> String {
        switch verdict {
        case .passed: return "eval ok"
        case .failedMargin: return "margin"
        case .insufficientSamples: return "samples"
        case .missing: return "no eval"
        case .staleRevision: return "stale rev"
        case .staleBaseModel: return "stale eval"
        case .nonFiniteScore: return "bad score"
        case .taskMismatch: return "wrong task"
        }
    }

    public static func label(for distribution: AdapterDescriptor.Distribution) -> String {
        switch distribution {
        case .bundled: return "bundled"
        case .remote: return "download"
        }
    }

    /// Two decimal places without Foundation's number formatting, so this stays portable.
    /// Rounds through `Saturating.clampToInt`, which is the only conversion in the package
    /// allowed to touch a `Double` that might be NaN.
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let scaled = Saturating.clampToInt((value * 100).rounded())
        let sign = scaled < 0 ? "-" : ""
        let magnitude = scaled == Int.min ? Int.max : abs(scaled)
        let whole = magnitude / 100
        let fraction = magnitude % 100
        let padded = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        return "\(sign)\(whole).\(padded)"
    }
}
