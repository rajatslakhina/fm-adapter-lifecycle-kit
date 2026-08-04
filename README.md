# FM Adapter Lifecycle Kit

**Your fine-tuned adapter did not break when the OS updated. It kept working, kept sounding fluent, and quietly stopped being better than the model you get for free.**

That is the failure mode this package exists for, and it is worse than a crash because nothing reports it.

iOS 27 adds on-device fine-tuning to the Foundation Models framework: you train LoRA adapter layers, ship a `.fmadapter`, and call `SystemLanguageModel(adapter:)`. Every guide stops there. But an adapter is trained against **one specific base model**, and on Apple platforms that base model ships with the OS and is replaced underneath you on Apple's schedule, not yours. The two-line integration is correct exactly until the first OS point release.

`AdapterLifecycle` is the layer that turns "we shipped an adapter" into something operable: a versioned registry with compatibility gating, an offline eval gate that is itself version-bound, a storage budget with an eviction order, staged rollout, a kill switch, quarantine, and a hard fallback to the stock model — with a machine-readable reason attached to every fallback.

---

## Why this matters

Three things are true at once, and together they make this a policy problem rather than an integration problem:

1. **You do not own the base model version.** It arrives with the OS. Your adapter's validity window is a claim about software you do not ship.
2. **Degradation is invisible.** A stale adapter still loads and still produces plausible text. There is no exception, no crash report, no error rate to alert on. The only signal is quality, which is exactly the signal mobile telemetry is worst at.
3. **The rollback surface is remote-only.** By the time you know, the build has shipped. Whatever controls you did not build in advance, you do not have.

So the deliverable is not a feature. It is a **personalisation and compatibility policy** other teams build against — the same shape as a feature-flag platform or a release-train policy, applied to a model artifact.

### The specific idea worth stealing

**An eval result is not a property of your adapter. It is a property of the pair (adapter revision, base model version).**

The base model was the other half of every measurement you took. When the OS replaces it, your numbers describe a system that no longer exists on the device. `EvalGate` therefore refuses to honour an eval recorded against a different base version, and the adapter stands down until it has been measured again:

```
base 27.0.0 → adapter serves,  delta +0.19 measured against 27.0.0
OS updates  → base 27.1.0
            → adapter is STILL COMPATIBLE (window is open-ended)
            → but the eval is stale, so it falls back to the base model
            → reason: .evalGate(.staleBaseModel(evaluatedAgainst: 27.0.0, installed: 27.1.0))
```

A compatibility check alone sails straight past this. `CoordinatorTests.testACompatibleAdapterStillStandsDownUntilItIsReEvaluated` is that scenario end to end.

---

## What's in it

| Type | Responsibility |
|---|---|
| `BaseModelVersion`, `BaseModelWindow` | Half-open validity windows, with `relation(to:)` reporting *which direction* the incompatibility runs — too-old usually resolves itself, too-new needs a new build |
| `AdapterDescriptor` | The artifact: revision, compatibility window, packaged size, bundled vs. downloaded |
| `EvalRecord`, `EvalGate` | The version-bound quality gate above. Eight distinct verdicts, all of which explain themselves |
| `RolloutPolicy`, `StableHash` | Staged availability on deterministic FNV-1a bucketing |
| `AdapterStorage` | Budget and eviction, as a pure value type. Incompatible artifacts go before cold ones; pinned and bundled never go |
| `DivergenceLedger` | Fixed-capacity online adapter-vs-base signal, invalidated on base model change |
| `ResolutionEngine` | The decision. Pure, synchronous, total. Returns a selection **and an audit trail of why every other candidate lost** |
| `AdapterLifecycleCoordinator` | The actor that owns state and I/O, with an epoch guard against reentrancy across `await` |
| `AdapterProvisioning` | The one-method seam to everything that touches bytes |
| `AdapterLifecycleUI` | A SwiftUI console that renders the decision and its audit trail |

The app never names a model. It asks `selection(for: task)` and gets back `.adapter(id, revision:)` or `.baseModel(reason:)`. That indirection is what makes rollout, rollback, quarantine and versioning possible without touching a single call site.

---

## Design decisions, and what was rejected

**A pure `ResolutionEngine` next to a stateful actor, rather than one actor that does everything.**
The decision is a total function of its inputs and holds nothing; the actor holds everything and decides nothing. In production the question "was this a bad policy or a bad state transition?" then has one file per answer. *Rejected:* a single actor — easier to write, but the policy becomes untestable without constructing a whole coordinator. *Rejected:* making everything pure and pushing state to the app — moves the reentrancy and eviction bugs into every adopter's codebase.

**Zero dependency on Foundation Models, and zero dependency on Foundation.**
The entire package is stdlib-only, with `AdapterProvisioning` as the single seam to bytes on disk. *Cost:* the app writes a small shim that fetches an artifact and constructs a session. *Benefit:* the policy — the part with the interesting bugs — compiles, runs and is tested on Linux CI in under a second, on a machine that has never heard of Apple Intelligence. Every test in this repo runs in both places. *Rejected:* typing against `SystemLanguageModel` directly, which would have made the package unbuildable outside a simulator and untestable in CI.

**FNV-1a for rollout bucketing, not `Hasher`.**
`Hasher` is seeded per process, so the same install lands in a different bucket on every launch: users drift in and out of the cohort and a 5% rollout touches far more than 5% of installs over a week. *Rejected:* `Hasher` (unstable across launches). *Rejected:* SHA-256 via CryptoKit (drags in a dependency to solve a problem FNV already solves, and is not available on Linux).

**Bucketing that does not depend on the exposure percentage.**
Folding the percentage into the hash is the common shortcut and it is subtly broken: ramping the rollout re-shuffles every device, so installs that already saw the adapter lose it. `RolloutPolicyTests` asserts the monotonicity invariant directly, **and** feeds the broken version to the same invariant to prove the assertion can actually detect it.

**An epoch counter for reentrancy, not a re-check of the compatibility predicate.**
`provision` checks compatibility, then `await`s a fetch — and an actor is reentrant across that suspension point. *Rejected:* re-running `compatibility.contains(installedBase)` after the await. It looks equivalent and is not: if the new base model is still inside the adapter's window, the re-check passes while the eval that authorised the adapter has gone stale. The epoch catches the state change itself rather than one predicate over it. `CoordinatorConcurrencyTests` drives exactly that interleaving with a fetch held open, plus a control case proving the test is not just observing that gated fetches never succeed.

**Every fallback carries a reason; there is no `Bool` anywhere in the decision.**
"The app used the base model" and "the app used the adapter" are indistinguishable from outside, so the decision has to explain itself every time or the system is unoperable. `ResolutionOutcome.audit` additionally records why each *losing* candidate lost, in order.

**Check order is deliberate, not incidental.**
Revocation → compatibility → quarantine → eval → rollout cohort. A kill switch is the only control that still works after the build shipped, so it outranks anything computed on the device. The rollout ramp is last because it is the softest signal, and reporting "not in the cohort yet" would mask a real incompatibility underneath. `ResolutionEngineTests.testAHardFailureIsReportedInsteadOfTheRolloutCohort` pins that.

**Bundled adapters are exempt from the managed storage budget.**
They are already paid for in app size and evicting one frees nothing. *Rejected:* counting them, which makes the budget describe something other than reclaimable bytes.

**All trapping arithmetic routes through one `Saturating` namespace.**
`Int(someDouble)` traps on NaN, on ±infinity and out of range; `%` and `/` trap on zero; `Int.min / -1` overflows. This code runs on the launch path of a shipped app, and the devices most likely to produce a bad value are the ones that just took an OS update — the exact population you least want in a crash loop. Bounds are derived from `Int.max`/`Int.min` rather than 64-bit literals, because `Int` is 32 bits wide on watchOS. *Rejected:* scattered `guard`s at call sites, which is how one gets missed.

---

## Using it

```swift
.package(url: "https://github.com/rajatslakhina/fm-adapter-lifecycle-kit.git", from: "1.0.0")
```

```swift
import AdapterLifecycle

let coordinator = AdapterLifecycleCoordinator(
    configuration: .init(
        installationID: stableInstallID,          // must survive launches and upgrades
        evalGate: EvalGate(minimumDelta: 0.05, minimumSampleCount: 200),
        rollout: RolloutPolicy(exposurePercent: 5),
        quarantineThreshold: 3,
        storageBudgetBytes: 256 * 1_048_576
    ),
    installedBase: BaseModelVersion(27, 0, 0),    // read from the framework at launch
    provisioner: MyDownloader()                   // your bytes, your signature checks
)

switch await coordinator.selection(for: .summarise).selection {
case let .adapter(id, _):
    // construct a session with this adapter
case let .baseModel(reason):
    // construct a stock session, and log `reason` — that is the whole point
}
```

When the OS moves the base model:

```swift
let report = await coordinator.baseModelDidChange(to: currentBaseVersion)
// report.evictedIncompatible  — artifacts that are now unusable bytes
// report.evalsInvalidated     — still installed, but must be re-evaluated before serving
```

---

## Not in scope, deliberately

This package decides **whether** to use an adapter. It does not download one, verify its signature, unpack it, or construct a `LanguageModelSession`. Those are the app's job, behind `AdapterProvisioning`. It also does not train adapters, and it does not read the installed base model version for you — the framework gives you that, and hard-coding the read would defeat the portability the seam buys.

Foundation Models on-device fine-tuning is entitlement-gated (`com.apple.developer.foundation-model-adapter`) and requires a separate signed agreement with Apple. This repository contains no adapter artifacts and no entitlement — the demo app runs the policy against a synthetic catalog.

---

## Verification

<!-- VERIFICATION -->

---

## Demo app

<!-- DEMO_LINK -->

---

## License

MIT — see [LICENSE](LICENSE).
