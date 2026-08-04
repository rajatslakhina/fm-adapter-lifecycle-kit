/// A deterministic, process-independent hash.
///
/// Deliberately **not** Swift's `Hasher`. `Hasher` is seeded per process, so `hashValue`
/// for the same string differs between launches by design. Bucketing an installation with
/// `Hasher` would re-roll the dice on every cold start: a user would drift in and out of
/// the rollout cohort, exposure telemetry would be meaningless, and a 5% rollout would
/// touch far more than 5% of installs over a week.
///
/// FNV-1a is chosen because it is tiny, has no dependencies, and — the property that
/// actually matters — is fully specified, so the bucket a device lands in is reproducible
/// off-device when you are trying to work out why one user saw the adapter.
/// `RolloutPolicyTests` pins it against digests computed independently from the spec.
public enum StableHash {
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            // Wrapping multiply is the algorithm, not an overflow bug.
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// Assigns an installation to a rollout bucket in `0..<RolloutPolicy.bucketCount`.
///
/// A protocol rather than a hardcoded function so the bucketing can be swapped — and, more
/// usefully, so a deliberately broken implementation can be pushed through the real
/// `RolloutPolicy` in tests. Without this seam a "mutation test" can only reimplement the
/// bad logic inline, which proves the *invariant* has teeth but proves nothing about
/// the code that ships.
public protocol AdapterBucketing: Sendable {
    func bucket(installationID: String, adapter: AdapterIdentifier) -> Int
}

/// The shipping implementation: FNV-1a over `adapter` and `installationID`.
public struct StableBucketing: AdapterBucketing {
    public init() {}

    public func bucket(installationID: String, adapter: AdapterIdentifier) -> Int {
        // U+001F (unit separator) cannot appear in a well-formed identifier, so this
        // avoids the ambiguity where ("ab", "c") and ("a", "bc") would hash identically.
        let digest = StableHash.fnv1a64("\(adapter.rawValue)\u{1F}\(installationID)")
        // `bucketCount` is a nonzero compile-time constant, so the remainder cannot trap,
        // and the result is in `0..<100`, which fits `Int` on every supported platform.
        return Int(digest % UInt64(RolloutPolicy.bucketCount))
    }
}

/// Staged availability for an adapter.
///
/// Entitlement-gated on-device fine-tuning does not remove the need for a rollout ramp —
/// it makes it more important, because the blast radius of a bad adapter is "the model
/// gives worse answers", which no crash reporter will tell you about.
public struct RolloutPolicy: Sendable {
    public static let bucketCount = 100

    /// Percentage of installations eligible, clamped to `0...100`.
    public let exposurePercent: Int
    private let bucketing: any AdapterBucketing

    public init(exposurePercent: Int, bucketing: any AdapterBucketing = StableBucketing()) {
        self.exposurePercent = min(Self.bucketCount, max(0, exposurePercent))
        self.bucketing = bucketing
    }

    /// The bucket an installation falls in for a given adapter, in `0..<100`.
    ///
    /// Note what this does *not* depend on: `exposurePercent`. Folding the percentage into
    /// the hash is a common and subtly broken shortcut — it makes ramping the rollout up
    /// re-shuffle every device, so installs that already saw the adapter lose it, and
    /// sticky bucketing across app upgrades is destroyed. Keeping the bucket independent of
    /// the threshold gives the invariant that widening exposure only ever *adds* installs.
    ///
    /// The result is sanitised because `bucketing` is a public seam: a third-party
    /// implementation returning an out-of-range value must not be able to make
    /// `includes(installationID:adapter:)` nonsensical.
    ///
    /// Out-of-range in **either** direction maps to the last bucket, which fails *closed*.
    /// Clamping negatives to `0` would have failed open — bucket 0 is inside every nonzero
    /// exposure, so one broken bucketing would turn a 1% rollout into 100%. A bug in
    /// someone else's hash should shrink a rollout, never widen it.
    public func bucket(installationID: String, adapter: AdapterIdentifier) -> Int {
        let raw = bucketing.bucket(installationID: installationID, adapter: adapter)
        guard raw >= 0, raw < Self.bucketCount else { return Self.bucketCount - 1 }
        return raw
    }

    public func includes(installationID: String, adapter: AdapterIdentifier) -> Bool {
        bucket(installationID: installationID, adapter: adapter) < exposurePercent
    }

    /// A copy at a new exposure, carrying the same bucketing.
    ///
    /// The reason this exists rather than callers constructing a fresh policy: rebuilding
    /// with the default bucketing on every ramp would re-shuffle every install, and the
    /// bug would only show up as drifting exposure metrics weeks later.
    public func withExposure(percent: Int) -> RolloutPolicy {
        RolloutPolicy(exposurePercent: percent, bucketing: bucketing)
    }
}
