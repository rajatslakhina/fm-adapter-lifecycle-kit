import XCTest
@testable import AdapterLifecycle

/// Bucketing that folds the exposure percentage into the hash — the shortcut that looks
/// right and destroys sticky rollout. Defined as a real `AdapterBucketing` so it can be
/// driven through the *shipping* `RolloutPolicy`, rather than reimplemented inline in a
/// test (which would prove the invariant has teeth while proving nothing about this code).
private struct ThresholdSensitiveBucketing: AdapterBucketing {
    let percent: Int
    func bucket(installationID: String, adapter: AdapterIdentifier) -> Int {
        Int(StableHash.fnv1a64("\(adapter.rawValue)\u{1F}\(installationID)\u{1F}\(percent)") % 100)
    }
}

/// Returns the same bucket for everyone. Deterministic and monotone, and completely
/// useless — which is the point: it is what several of the weaker assertions below cannot
/// distinguish from the real thing.
private struct ConstantBucketing: AdapterBucketing {
    let value: Int
    func bucket(installationID: String, adapter: AdapterIdentifier) -> Int { value }
}

/// Deliberately out of range, to prove `RolloutPolicy` clamps what a third-party
/// implementation hands back rather than trusting it.
private struct OutOfRangeBucketing: AdapterBucketing {
    let value: Int
    func bucket(installationID: String, adapter: AdapterIdentifier) -> Int { value }
}

final class RolloutPolicyTests: XCTestCase {

    private let summariser = AdapterIdentifier("summariser.v3")
    private let tone = AdapterIdentifier("tone.v1")

    // MARK: - Stability

    /// Golden values, computed independently from the FNV-1a 64 specification rather than
    /// captured from this implementation's own output.
    ///
    /// This is the test that actually pins the hash. "Call it twice and check the answers
    /// match" would pass against Swift's `Hasher` too — `Hasher` is stable *within* a
    /// process and only re-seeds between launches, so a same-process consistency check is
    /// exactly the assertion that cannot detect the bug it was written for. Hard-coded
    /// digests fail the moment the algorithm changes.
    func testBucketsMatchIndependentlyComputedFNV1aValues() {
        let policy = RolloutPolicy(exposurePercent: 100)
        XCTAssertEqual(policy.bucket(installationID: "install-A", adapter: summariser), 18)
        XCTAssertEqual(policy.bucket(installationID: "install-B", adapter: summariser), 7)
        XCTAssertEqual(policy.bucket(installationID: "install-C", adapter: summariser), 96)
        XCTAssertEqual(policy.bucket(installationID: "install-A", adapter: tone), 66)
    }

    func testRawDigestMatchesTheFNV1aSpecification() {
        // FNV-1a 64 of the empty string is the offset basis, unchanged.
        XCTAssertEqual(StableHash.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableHash.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    func testTheSameInstallationLandsInDifferentBucketsForDifferentAdapters() {
        let policy = RolloutPolicy(exposurePercent: 100)
        XCTAssertNotEqual(
            policy.bucket(installationID: "install-A", adapter: summariser),
            policy.bucket(installationID: "install-A", adapter: tone),
            "bucketing must be per-adapter, or every rollout hits the same unlucky cohort"
        )
    }

    /// The separator matters: without it ("ab", "c") and ("a", "bc") would collide.
    func testIdentifierBoundaryIsUnambiguous() {
        let policy = RolloutPolicy(exposurePercent: 100)
        XCTAssertNotEqual(
            policy.bucket(installationID: "c", adapter: AdapterIdentifier("ab")),
            policy.bucket(installationID: "bc", adapter: AdapterIdentifier("a"))
        )
    }

    // MARK: - Clamping

    func testExposureIsClampedToARealPercentage() {
        XCTAssertEqual(RolloutPolicy(exposurePercent: -40).exposurePercent, 0)
        XCTAssertEqual(RolloutPolicy(exposurePercent: 400).exposurePercent, 100)
        XCTAssertEqual(RolloutPolicy(exposurePercent: Int.min).exposurePercent, 0)
        XCTAssertEqual(RolloutPolicy(exposurePercent: Int.max).exposurePercent, 100)
    }

    /// `bucketing` is a public seam, so a third-party implementation returning garbage must
    /// not be able to make `includes` nonsensical — e.g. a negative bucket would otherwise
    /// be `< 0`, putting an install into a 0% rollout.
    func testAnOutOfRangeBucketFromAThirdPartyImplementationIsClamped() {
        let negative = RolloutPolicy(exposurePercent: 0, bucketing: OutOfRangeBucketing(value: -5))
        XCTAssertEqual(negative.bucket(installationID: "x", adapter: summariser), 0)
        XCTAssertFalse(
            negative.includes(installationID: "x", adapter: summariser),
            "a negative bucket must not sneak an install into a 0% rollout"
        )

        let huge = RolloutPolicy(exposurePercent: 100, bucketing: OutOfRangeBucketing(value: 10_000))
        XCTAssertEqual(huge.bucket(installationID: "x", adapter: summariser), 99)
        XCTAssertTrue(
            huge.includes(installationID: "x", adapter: summariser),
            "and an oversized bucket must not exclude an install from a 100% rollout"
        )
    }

    func testFullExposureIncludesEveryone() {
        let full = RolloutPolicy(exposurePercent: 100)
        for n in 0..<300 {
            XCTAssertTrue(full.includes(installationID: "install-\(n)", adapter: summariser))
        }
    }

    /// Zero exposure has to exclude everyone even when the bucketing hands back 0 for
    /// everybody — `bucket < 0` must be false, not `bucket <= 0`. An off-by-one here would
    /// leak the adapter to a slice of the fleet with the rollout nominally switched off,
    /// which is the worst possible time to have an off-by-one.
    func testZeroExposureExcludesEveryoneEvenAtTheBoundaryBucket() {
        let off = RolloutPolicy(exposurePercent: 0, bucketing: ConstantBucketing(value: 0))
        XCTAssertEqual(off.bucket(installationID: "x", adapter: summariser), 0)
        XCTAssertFalse(off.includes(installationID: "x", adapter: summariser))

        let realOff = RolloutPolicy(exposurePercent: 0)
        for n in 0..<300 {
            XCTAssertFalse(realOff.includes(installationID: "install-\(n)", adapter: summariser))
        }
    }

    /// The boundary in the other direction: bucket 4 is inside a 5% rollout, bucket 5 is
    /// not. `<=` instead of `<` would make every rollout one point wider than declared.
    func testTheCohortBoundaryIsExclusive() {
        let inside = RolloutPolicy(exposurePercent: 5, bucketing: ConstantBucketing(value: 4))
        let outside = RolloutPolicy(exposurePercent: 5, bucketing: ConstantBucketing(value: 5))
        XCTAssertTrue(inside.includes(installationID: "x", adapter: summariser))
        XCTAssertFalse(outside.includes(installationID: "x", adapter: summariser))
    }

    // MARK: - The invariant

    /// Widening a rollout must only ever *add* installations. An install that saw the
    /// adapter at 10% must still see it at 20%, or users watch a feature appear and vanish
    /// as the ramp goes up, and every exposure metric becomes uninterpretable.
    func testWideningExposureNeverRemovesAnInstallation() {
        var everIncluded: Set<String> = []
        for percent in 0...100 {
            let policy = RolloutPolicy(exposurePercent: percent)
            var includedNow: Set<String> = []
            for n in 0..<400 {
                let id = "install-\(n)"
                if policy.includes(installationID: id, adapter: summariser) { includedNow.insert(id) }
            }
            XCTAssertTrue(
                everIncluded.isSubset(of: includedNow),
                "at \(percent)% these installs lost the adapter: \(everIncluded.subtracting(includedNow).sorted())"
            )
            everIncluded.formUnion(includedNow)
        }
        XCTAssertEqual(everIncluded.count, 400, "at 100% every install should be in the cohort")
    }

    /// The mutation check for the test above — and it runs the broken bucketing through the
    /// **real** `RolloutPolicy.includes`, not a reimplementation of it. That is what the
    /// `AdapterBucketing` seam exists for: without it this test could only demonstrate that
    /// the invariant is violable in principle, which says nothing about the shipping code.
    func testTheMonotonicityInvariantCatchesThresholdSensitiveBucketingThroughTheRealPolicy() {
        var everIncluded: Set<String> = []
        var sawAnInstallLoseTheAdapter = false
        for percent in 0...100 {
            let policy = RolloutPolicy(
                exposurePercent: percent,
                bucketing: ThresholdSensitiveBucketing(percent: percent)
            )
            var includedNow: Set<String> = []
            for n in 0..<400 {
                let id = "install-\(n)"
                if policy.includes(installationID: id, adapter: summariser) { includedNow.insert(id) }
            }
            if !everIncluded.isSubset(of: includedNow) { sawAnInstallLoseTheAdapter = true }
            everIncluded.formUnion(includedNow)
        }
        XCTAssertTrue(
            sawAnInstallLoseTheAdapter,
            "the broken bucketing must violate the invariant when run through RolloutPolicy, "
                + "otherwise the monotonicity test proves nothing"
        )
    }

    // MARK: - Distribution

    /// A hash that returned a constant would satisfy determinism, the boundary tests and
    /// monotonicity, while making a 10% rollout hit either nobody or everybody. This is the
    /// assertion that rules it out, so it is stated against both implementations.
    func testBucketsAreSpreadAcrossTheRange() {
        let policy = RolloutPolicy(exposurePercent: 10)
        let sample = 2_000
        var included = 0
        var occupied: Set<Int> = []
        for n in 0..<sample {
            let id = "install-\(n)"
            occupied.insert(policy.bucket(installationID: id, adapter: summariser))
            if policy.includes(installationID: id, adapter: summariser) { included += 1 }
        }
        XCTAssertEqual(occupied.count, 100, "every bucket should be reachable")
        XCTAssertGreaterThan(included, 150, "10% of \(sample) landed far below expectation")
        XCTAssertLessThan(included, 270, "10% of \(sample) landed far above expectation")

        // Control: the degenerate implementation fails exactly this assertion.
        let degenerate = RolloutPolicy(exposurePercent: 10, bucketing: ConstantBucketing(value: 3))
        var degenerateOccupied: Set<Int> = []
        for n in 0..<sample {
            degenerateOccupied.insert(degenerate.bucket(installationID: "install-\(n)", adapter: summariser))
        }
        XCTAssertEqual(degenerateOccupied.count, 1, "control: a constant hash occupies one bucket")
    }
}
