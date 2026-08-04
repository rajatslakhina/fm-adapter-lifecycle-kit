/// A deterministic, process-independent hash.
///
/// Deliberately **not** Swift's `Hasher`. `Hasher` is seeded per process, so
/// `hashValue` for the same string differs between launches by design. Bucketing an
/// installation with `Hasher` would re-roll the dice on every cold start: a user would
/// drift in and out of the rollout cohort, exposure telemetry would be meaningless, and
/// a 5% rollout would touch far more than 5% of installs over a week.
///
/// FNV-1a is chosen because it is tiny, has no dependencies, and — the property that
/// actually matters — is fully specified, so the bucket a device lands in is reproducible
/// off-device when you are trying to work out why one user saw the adapter.
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

/// Staged availability for an adapter.
///
/// Entitlement-gated on-device fine-tuning does not remove the need for a rollout ramp —
/// it makes it more important, because the blast radius of a bad adapter is "the model
/// gives worse answers", which no crash reporter will tell you about.
public struct RolloutPolicy: Sendable, Hashable {
    public static let bucketCount = 100

    /// Percentage of installations eligible, clamped to `0...100`.
    public let exposurePercent: Int

    public init(exposurePercent: Int) {
        self.exposurePercent = min(Self.bucketCount, max(0, exposurePercent))
    }

    /// The bucket an installation falls in for a given adapter, in `0..<100`.
    ///
    /// Note what this does *not* depend on: `exposurePercent`. Folding the percentage
    /// into the hash is a common and subtly broken shortcut — it makes ramping the
    /// rollout up re-shuffle every device, so installs that already saw the adapter can
    /// lose it, and sticky bucketing across app upgrades is destroyed. Keeping the bucket
    /// independent of the threshold gives the invariant that widening exposure only ever
    /// *adds* installs, which `RolloutPolicyTests` asserts directly.
    public func bucket(installationID: String, adapter: AdapterIdentifier) -> Int {
        // U+001F (unit separator) cannot appear in a well-formed identifier, so this
        // avoids the ambiguity where ("ab", "c") and ("a", "bc") hash identically.
        let digest = StableHash.fnv1a64("\(adapter.rawValue)\u{1F}\(installationID)")
        // `bucketCount` is a nonzero compile-time constant, so the remainder cannot trap,
        // and the result is in `0..<100` so it fits `Int` on every supported platform.
        return Int(digest % UInt64(Self.bucketCount))
    }

    public func includes(installationID: String, adapter: AdapterIdentifier) -> Bool {
        bucket(installationID: installationID, adapter: adapter) < exposurePercent
    }
}
