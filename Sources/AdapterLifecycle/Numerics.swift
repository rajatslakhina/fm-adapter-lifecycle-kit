/// Arithmetic that cannot trap.
///
/// Every numeric operation in this package that could trap at runtime routes through
/// this namespace. That is a deliberate policy, not defensive habit: adapter lifecycle
/// code runs on the launch path of an app that has already shipped, and the population
/// most likely to hit a bad value is the population that just took an OS update — which
/// is the exact population you least want to put into a crash loop.
///
/// The operations Swift will trap on, and which are therefore banned in this module
/// outside of these helpers:
/// - `Int(someDouble)` — traps on NaN, on ±infinity, and outside `Int`'s range.
/// - `%` and `/` with a zero divisor.
/// - `Int.min / -1` — the one division that overflows.
/// - `+`, `-`, `*` on `Int` when the true result does not fit.
public enum Saturating {

    /// `a + b`, clamped to `Int.min ... Int.max` instead of trapping.
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (sum, overflowed) = a.addingReportingOverflow(b)
        guard overflowed else { return sum }
        return b > 0 ? Int.max : Int.min
    }

    /// `a - b`, clamped to `Int.min ... Int.max` instead of trapping.
    public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (difference, overflowed) = a.subtractingReportingOverflow(b)
        guard overflowed else { return difference }
        return b > 0 ? Int.min : Int.max
    }

    /// `value` expressed as a whole percentage of `total`, clamped to `0...100`.
    ///
    /// Returns `0` when `total <= 0` rather than dividing by zero, and falls back to
    /// floating point when `value * 100` would overflow.
    public static func percent(_ value: Int, of total: Int) -> Int {
        guard total > 0, value > 0 else { return 0 }
        guard value < total else { return 100 }
        let (scaled, overflowed) = value.multipliedReportingOverflow(by: 100)
        if !overflowed {
            // `total > 0` was established above, so this division cannot trap.
            return scaled / total
        }
        // `total > 0` so the divisor is nonzero and the quotient is in `0..<1`.
        return clampToInt((Double(value) / Double(total)) * 100)
    }

    /// `Int(d)` without the trap.
    ///
    /// NaN is the only input with no sensible numeric answer, so it maps to zero.
    /// Infinities are *not* lumped in with it: they have a direction, and collapsing
    /// `+∞` to `0` would turn an overflowed measurement into a plausible-looking small
    /// number, which is a worse bug than the trap it replaced.
    ///
    /// The bounds are derived from `Int.max`/`Int.min` rather than written as 64-bit
    /// literals, because `Int` is 32 bits wide on watchOS. `Double(Int.max)` rounds *up*
    /// to 2^63 on a 64-bit platform, which is why the comparison is `>=`: every `Double`
    /// strictly below that bound is representable as an `Int`.
    public static func clampToInt(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d >= Double(Int.max) { return Int.max }   // also catches +infinity
        if d <= Double(Int.min) { return Int.min }   // also catches -infinity
        return Int(d)
    }

    /// Clamps a byte count or sample count to `0...`, so a negative input can never
    /// inflate a storage budget by being subtracted from it.
    public static func nonNegative(_ value: Int) -> Int { max(0, value) }
}
