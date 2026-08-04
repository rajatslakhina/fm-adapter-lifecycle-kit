/// The version of the *base* model an adapter is bound to.
///
/// This is the type the whole package exists for. A LoRA adapter is trained against one
/// specific base model, and on Apple platforms that base model ships with the OS and is
/// replaced underneath the app on the vendor's schedule, not the team's. So "which base
/// model is on this device right now" is an input to every decision here, and an adapter
/// is never valid in the abstract — only valid *against a version*.
public struct BaseModelVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Negative components are clamped to zero rather than rejected, so a malformed
    /// value read back from disk degrades to "very old base model" — which fails closed
    /// into the stock-model fallback — instead of trapping or being silently ordered
    /// above a real version.
    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = Saturating.nonNegative(major)
        self.minor = Saturating.nonNegative(minor)
        self.patch = Saturating.nonNegative(patch)
    }

    /// Parses `"27"`, `"27.1"`, or `"27.1.3"`. Returns `nil` for anything else, including
    /// negative components, empty fields, and integers too large for `Int`
    /// (`Int(_:)` returns `nil` in that case rather than trapping).
    public init?(parsing text: String) {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }
        // Literal three-element array: indices 0, 1 and 2 are statically in bounds, and
        // the `where` clause keeps the write in range even if `fields` ever grew.
        var components = [0, 0, 0]
        for (offset, field) in fields.enumerated() where offset < components.count {
            guard let value = Int(field), value >= 0 else { return nil }
            components[offset] = value
        }
        self.init(components[0], components[1], components[2])
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// The half-open range of base model versions an adapter declares itself valid for.
///
/// Half-open on purpose. The failure this package is built around is an OS update moving
/// the base model forward, so the interesting bound is the upper one, and "valid up to
/// but not including the next base generation" is the semantics that lets a team ship an
/// adapter before they know what the next version number will be.
public struct BaseModelWindow: Sendable, Hashable, CustomStringConvertible {
    public let lowerBound: BaseModelVersion
    /// `nil` means open-ended. That is a real and dangerous choice — it asserts the
    /// adapter will keep working against base models that do not exist yet — so callers
    /// are expected to use it only for adapters they are prepared to roll back remotely.
    public let upperBoundExclusive: BaseModelVersion?

    public init(from lowerBound: BaseModelVersion, upTo upperBoundExclusive: BaseModelVersion? = nil) {
        self.lowerBound = lowerBound
        self.upperBoundExclusive = upperBoundExclusive
    }

    /// True when no version can satisfy this window at all, because the upper bound is at
    /// or below the lower bound. A window built from a bad remote config lands here, and
    /// `relation(to:)` reports every version as incompatible in one direction or the other
    /// — below the lower bound it reads `.installedTooOld`, at or above it `.installedTooNew`
    /// — so resolution always fails closed to the base model.
    public var isEmpty: Bool {
        guard let upper = upperBoundExclusive else { return false }
        return upper <= lowerBound
    }

    public func contains(_ version: BaseModelVersion) -> Bool {
        relation(to: version) == .satisfied
    }

    /// Why a version does or does not satisfy the window. The direction matters to the
    /// caller: too-old is usually a device that has not taken the update yet and will
    /// resolve itself, too-new is an adapter that needs a new build.
    public func relation(to version: BaseModelVersion) -> Relation {
        if version < lowerBound { return .installedTooOld }
        if let upper = upperBoundExclusive, version >= upper { return .installedTooNew }
        return .satisfied
    }

    public enum Relation: Sendable, Hashable {
        case satisfied
        case installedTooOld
        case installedTooNew
    }

    public var description: String {
        guard let upper = upperBoundExclusive else { return "[\(lowerBound), ∞)" }
        return "[\(lowerBound), \(upper))"
    }
}
