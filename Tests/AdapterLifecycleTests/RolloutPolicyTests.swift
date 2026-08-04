import XCTest
@testable import AdapterLifecycle

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
        // "a" -> basis XOR 0x61, times the prime.
        XCTAssertEqual(StableHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableHash.fnv1a64("foobar"), 0x85944171f73967e8)
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

    func testZeroPercentExcludesEveryoneAndOneHundredIncludesEveryone() {
        let off = RolloutPolicy(exposurePercent: 0)
        let full = RolloutPolicy(exposurePercent: 100)
        for n in 0..<300 {
            let id = "install-\(n)"
            XCTAssertFalse(off.includes(installationID: id, adapter: summariser))
            XCTAssertTrue(full.includes(installationID: id, adapter: summariser))
        }
    }

    // MARK: - The invariant

    /// Widening a rollout must only ever *add* installations. An install that saw the
    /// adapter at 10% must still see it at 20%, or users watch a feature appear and
    /// vanish as the ramp goes up, and every exposure metric becomes uninterpretable.
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

    /// The mutation check for the test above.
    ///
    /// `brokenBucket` is the shortcut that folds the exposure percentage into the hash —
    /// plausible-looking, and it passes every other test in this file. Here it is fed to
    /// the same invariant, and the assertion is that the invariant **fails** for it. If
    /// this test ever stops finding a violation, the monotonicity test above has stopped
    /// being able to detect the bug it exists for.
    func testTheMonotonicityInvariantActuallyDetectsAThresholdSensitiveBucketing() {
        func brokenBucket(installationID: String, percent: Int) -> Int {
            Int(StableHash.fnv1a64("\(summariser.rawValue)\u{1F}\(installationID)\u{1F}\(percent)") % 100)
        }

        var everIncluded: Set<String> = []
        var sawAnInstallLoseTheAdapter = false
        for percent in 0...100 {
            var includedNow: Set<String> = []
            for n in 0..<400 {
                let id = "install-\(n)"
                if brokenBucket(installationID: id, percent: percent) < percent { includedNow.insert(id) }
            }
            if !everIncluded.isSubset(of: includedNow) { sawAnInstallLoseTheAdapter = true }
            everIncluded.formUnion(includedNow)
        }
        XCTAssertTrue(
            sawAnInstallLoseTheAdapter,
            "the broken bucketing must violate the invariant, otherwise the monotonicity test proves nothing"
        )
    }

    // MARK: - Distribution

    /// A hash that returned a constant would satisfy determinism and monotonicity but
    /// make a 10% rollout hit either nobody or everybody.
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
    }
}
