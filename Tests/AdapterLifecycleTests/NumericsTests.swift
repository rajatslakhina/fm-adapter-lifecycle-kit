import XCTest
@testable import AdapterLifecycle

/// Every case here is an expression that traps in plain Swift. `Int(Double.nan)` is not a
/// hypothetical: it is one line of arithmetic away from any code that turns a measured
/// score into a bucket, and it takes the process down with no recoverable error.
final class NumericsTests: XCTestCase {

    func testAddSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.max, Int.max), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(Int.min, Int.min), Int.min)
        XCTAssertEqual(Saturating.add(2, 3), 5)
        XCTAssertEqual(Saturating.add(Int.max, 0), Int.max)
        XCTAssertEqual(Saturating.add(-5, 5), 0)
    }

    func testSubtractSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(Saturating.subtract(Int.min, 1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.max, -1), Int.max)
        XCTAssertEqual(Saturating.subtract(Int.min, Int.max), Int.min)
        XCTAssertEqual(Saturating.subtract(10, 4), 6)
        XCTAssertEqual(Saturating.subtract(4, 10), -6)
    }

    func testPercentNeverDividesByZero() {
        XCTAssertEqual(Saturating.percent(50, of: 0), 0)
        XCTAssertEqual(Saturating.percent(0, of: 0), 0)
        XCTAssertEqual(Saturating.percent(1, of: -10), 0)
    }

    func testPercentClampsAndTruncates() {
        XCTAssertEqual(Saturating.percent(50, of: 200), 25)
        XCTAssertEqual(Saturating.percent(200, of: 200), 100)
        XCTAssertEqual(Saturating.percent(500, of: 200), 100)
        XCTAssertEqual(Saturating.percent(-5, of: 200), 0)
        XCTAssertEqual(Saturating.percent(1, of: 3), 33, "integer division truncates; nothing here rounds")
    }

    /// `value * 100` overflows here, so the integer path is unusable and the helper has
    /// to fall back to floating point without losing the clamp.
    func testPercentSurvivesMultiplicationOverflow() {
        let huge = Int.max / 2
        let total = Int.max
        let result = Saturating.percent(huge, of: total)
        XCTAssertEqual(result, 50, "half of Int.max should read as 50%, not overflow")
    }

    /// Infinity saturates in its own direction rather than collapsing to zero with NaN.
    /// Mapping `+∞` to `0` would quietly turn an overflowed measurement into a small,
    /// believable number — harder to notice than the crash it replaced.
    func testClampToIntHandlesEveryValueIntWouldTrapOn() {
        XCTAssertEqual(Saturating.clampToInt(.nan), 0)
        XCTAssertEqual(Saturating.clampToInt(.signalingNaN), 0)
        XCTAssertEqual(Saturating.clampToInt(.infinity), Int.max)
        XCTAssertEqual(Saturating.clampToInt(-.infinity), Int.min)
        XCTAssertEqual(Saturating.clampToInt(1e300), Int.max)
        XCTAssertEqual(Saturating.clampToInt(-1e300), Int.min)
        XCTAssertEqual(Saturating.clampToInt(Double(Int.max)), Int.max)
        XCTAssertEqual(Saturating.clampToInt(Double(Int.min)), Int.min)
    }

    func testClampToIntTruncatesTowardZeroInRange() {
        XCTAssertEqual(Saturating.clampToInt(3.9), 3)
        XCTAssertEqual(Saturating.clampToInt(-3.9), -3)
        XCTAssertEqual(Saturating.clampToInt(0), 0)
        XCTAssertEqual(Saturating.clampToInt(-0.0), 0)
    }

    func testNonNegativeClampsBelowZero() {
        XCTAssertEqual(Saturating.nonNegative(-1), 0)
        XCTAssertEqual(Saturating.nonNegative(Int.min), 0)
        XCTAssertEqual(Saturating.nonNegative(7), 7)
    }
}
