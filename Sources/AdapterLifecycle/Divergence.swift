/// A bounded record of how the adapter is doing against the base model *in production*,
/// after the offline eval gate has already said yes.
///
/// The offline gate proves the adapter was better on a fixed dataset at build time. This
/// is the other half: the online signal that tells you the OS updated, or the user's data
/// drifted, and the thing you measured six weeks ago is now losing. It is fixed-capacity
/// by construction — an unbounded telemetry buffer on a device is a memory leak with a
/// business justification.
public struct DivergenceLedger: Sendable {

    public struct Entry: Sendable, Hashable {
        public enum Winner: Sendable, Hashable { case adapter, base, tie }
        public let adapter: AdapterIdentifier
        public let task: TaskIdentifier
        public let baseModel: BaseModelVersion
        public let winner: Winner

        public init(adapter: AdapterIdentifier, task: TaskIdentifier, baseModel: BaseModelVersion, winner: Winner) {
            self.adapter = adapter
            self.task = task
            self.baseModel = baseModel
            self.winner = winner
        }
    }

    public struct Summary: Sendable, Hashable {
        public let adapterWins: Int
        public let baseWins: Int
        public let ties: Int
        public var sampleCount: Int { Saturating.add(Saturating.add(adapterWins, baseWins), ties) }
        /// Share of decided comparisons the base model won, `0...100`. Ties are excluded
        /// from the denominator: a tie is not evidence the adapter is regressing.
        public var regressionPercent: Int {
            Saturating.percent(baseWins, of: Saturating.add(adapterWins, baseWins))
        }
    }

    public let capacity: Int
    private var entries: [Entry] = []
    private var writeIndex: Int = 0

    /// `capacity` is clamped to at least 1 so the modulo in `record(_:)` can never see a
    /// zero divisor.
    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        entries.reserveCapacity(self.capacity)
    }

    public var count: Int { entries.count }

    public mutating func record(_ entry: Entry) {
        if entries.count < capacity {
            entries.append(entry)
            // `capacity >= 1`, so this remainder is safe. When the buffer has just filled,
            // this lands on 0 — the correct next slot to overwrite.
            writeIndex = entries.count % capacity
            return
        }
        guard entries.indices.contains(writeIndex) else {
            // Unreachable given the invariant `writeIndex < capacity == entries.count`,
            // but a bounds check is cheaper than a crash if that invariant ever breaks.
            return
        }
        entries[writeIndex] = entry
        writeIndex = (writeIndex &+ 1) % capacity
    }

    /// Summary over the retained window, optionally scoped to one adapter.
    public func summary(for adapter: AdapterIdentifier? = nil) -> Summary {
        var adapterWins = 0, baseWins = 0, ties = 0
        for entry in entries where adapter == nil || entry.adapter == adapter {
            switch entry.winner {
            case .adapter: adapterWins = Saturating.add(adapterWins, 1)
            case .base: baseWins = Saturating.add(baseWins, 1)
            case .tie: ties = Saturating.add(ties, 1)
            }
        }
        return Summary(adapterWins: adapterWins, baseWins: baseWins, ties: ties)
    }

    /// Drops every entry recorded against a base model other than `installedBase`.
    ///
    /// Called when the OS moves the base model. Same reasoning as the eval gate: a
    /// comparison against the old base model says nothing about the new one, and leaving
    /// it in the window would let stale data suppress a real regression signal.
    public mutating func invalidate(keeping installedBase: BaseModelVersion) {
        entries = entries.filter { $0.baseModel == installedBase }
        writeIndex = entries.count % capacity
    }
}
