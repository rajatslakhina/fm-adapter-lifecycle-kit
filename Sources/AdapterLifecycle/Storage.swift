/// The device-side cache of adapter artifacts, with a hard budget and an eviction order.
///
/// Written as a value type on purpose. Storage accounting and eviction are pure decisions
/// over a small amount of state, so they belong in something that can be driven through
/// thousands of deterministic transitions in a unit test. `AdapterLifecycleCoordinator`
/// owns an instance of this and supplies the concurrency and the I/O; nothing in here
/// touches a disk. That split is the reason the eviction-under-pressure cases are cheap
/// to test at all.
public struct AdapterStorage: Sendable {

    public struct Resident: Sendable, Hashable {
        public let descriptor: AdapterDescriptor
        /// Logical clock, not wall time. LRU only needs an ordering, and a monotonic
        /// counter is immune to clock changes, timezone shifts and test flakiness.
        public internal(set) var lastAccessTick: UInt64
        /// Pinned residents are exempt from LRU eviction. Used for the adapters currently
        /// serving traffic, so a background fetch cannot evict a model in active use.
        public internal(set) var isPinned: Bool

        public init(descriptor: AdapterDescriptor, lastAccessTick: UInt64, isPinned: Bool) {
            self.descriptor = descriptor
            self.lastAccessTick = lastAccessTick
            self.isPinned = isPinned
        }
    }

    public enum AdmissionOutcome: Sendable, Equatable {
        case admitted(evicted: [AdapterIdentifier])
        case alreadyResident
        /// Even after evicting everything evictable, the artifact does not fit.
        /// `availableBytes` is what was actually free at the moment of refusal — not the
        /// whole budget — so the message a user or a log reader sees is the true headroom.
        case rejectedExceedsBudget(payloadBytes: Int, availableBytes: Int)
        /// Refused before spending a byte: this artifact cannot run on the installed base
        /// model, so caching it is pure waste.
        case rejectedIncompatible(window: BaseModelWindow, installed: BaseModelVersion)
        /// The byte budget has room but the resident count is at its ceiling. Bundled and
        /// zero-byte artifacts consume no bytes, so without this the resident set is
        /// unbounded even though `usedBytes` never moves.
        case rejectedTooManyResidents(limit: Int)
    }

    public private(set) var budgetBytes: Int
    /// Hard ceiling on how many artifacts may be resident regardless of their size.
    public let maximumResidents: Int
    private var residents: [AdapterIdentifier: Resident] = [:]
    private var tick: UInt64 = 0

    public init(budgetBytes: Int, maximumResidents: Int = 32) {
        self.budgetBytes = Saturating.nonNegative(budgetBytes)
        self.maximumResidents = max(1, maximumResidents)
    }

    // MARK: - Queries

    /// Bytes consumed by remote artifacts. Bundled adapters are excluded: they live in
    /// the app bundle, evicting one frees nothing, and counting them would make the
    /// budget a lie.
    public var usedBytes: Int {
        residents.values.reduce(0) { total, resident in
            guard resident.descriptor.consumesManagedStorage else { return total }
            return Saturating.add(total, resident.descriptor.payloadBytes)
        }
    }

    public var availableBytes: Int { Saturating.subtract(budgetBytes, usedBytes) }

    public var utilisationPercent: Int { Saturating.percent(usedBytes, of: budgetBytes) }

    public var residentIdentifiers: [AdapterIdentifier] { residents.keys.sorted() }

    public func resident(_ id: AdapterIdentifier) -> Resident? { residents[id] }

    public func isResident(_ id: AdapterIdentifier) -> Bool { residents[id] != nil }

    /// Residents for a task, best candidate first: highest revision wins, ties broken by
    /// identifier so the order is total and reproducible rather than dictionary order.
    public func candidates(for task: TaskIdentifier) -> [AdapterDescriptor] {
        residents.values
            .map(\.descriptor)
            .filter { $0.task == task }
            .sorted { lhs, rhs in
                if lhs.revision != rhs.revision { return lhs.revision > rhs.revision }
                return lhs.id < rhs.id
            }
    }

    // MARK: - Mutation

    /// Attempts to make `descriptor` resident, evicting as needed.
    ///
    /// Eviction order, worst-value-first:
    /// 1. Residents that cannot run on `installedBase` at all — dead weight by definition.
    /// 2. Unpinned residents, least recently used first.
    /// Pinned residents and bundled residents are never evicted.
    public mutating func admit(
        _ descriptor: AdapterDescriptor,
        installedBase: BaseModelVersion
    ) -> AdmissionOutcome {
        if residents[descriptor.id] != nil {
            touch(descriptor.id)
            return .alreadyResident
        }
        guard descriptor.compatibility.contains(installedBase) else {
            return .rejectedIncompatible(window: descriptor.compatibility, installed: installedBase)
        }

        guard residents.count < maximumResidents else {
            return .rejectedTooManyResidents(limit: maximumResidents)
        }

        guard descriptor.consumesManagedStorage else {
            // Bundled: no budget to check, it is already on the device.
            insert(descriptor)
            return .admitted(evicted: [])
        }

        let payload = descriptor.payloadBytes
        // Reported against the free space, not the whole budget: "400 MB will not fit in
        // 60 MB" is actionable, "400 MB will not fit in 220 MB" is confusing when 160 MB
        // of that 220 is already spoken for.
        guard payload <= budgetBytes else {
            return .rejectedExceedsBudget(payloadBytes: payload, availableBytes: availableBytes)
        }

        var evicted: [AdapterIdentifier] = []
        // Each iteration removes exactly one resident or breaks, and `residents` is
        // finite, so this terminates.
        while Saturating.add(usedBytes, payload) > budgetBytes {
            guard let victim = nextEvictionVictim(installedBase: installedBase) else { break }
            residents.removeValue(forKey: victim)
            evicted.append(victim)
        }

        guard Saturating.add(usedBytes, payload) <= budgetBytes else {
            // Put back nothing — the evicted artifacts were either incompatible or cold,
            // and re-admitting them would need a fetch anyway. Report honestly.
            return .rejectedExceedsBudget(payloadBytes: payload, availableBytes: availableBytes)
        }
        insert(descriptor)
        return .admitted(evicted: evicted)
    }

    /// Marks a resident as most recently used. No-op for an unknown identifier.
    public mutating func touch(_ id: AdapterIdentifier) {
        guard var resident = residents[id] else { return }
        resident.lastAccessTick = nextTick()
        residents[id] = resident
    }

    public mutating func setPinned(_ pinned: Bool, for id: AdapterIdentifier) {
        guard var resident = residents[id] else { return }
        resident.isPinned = pinned
        residents[id] = resident
    }

    /// Pins exactly the given set and unpins everything else.
    ///
    /// Takes a *set*, not a single identifier. An app with more than one task has more than
    /// one adapter serving at a time, and an earlier version of this took one id — which
    /// meant resolving task B silently unpinned the adapter still serving task A, and a
    /// background fetch could then evict a model in active use. That is exactly the
    /// guarantee this method exists to provide, so the signature has to be able to express
    /// it. `CoordinatorTests.testResolvingASecondTaskDoesNotUnpinTheFirstTasksAdapter`
    /// covers the regression.
    public mutating func setPinned(exactly pinned: Set<AdapterIdentifier>) {
        for key in residents.keys {
            guard var resident = residents[key] else { continue }
            resident.isPinned = pinned.contains(key)
            residents[key] = resident
        }
    }

    @discardableResult
    public mutating func evict(_ id: AdapterIdentifier) -> Bool {
        residents.removeValue(forKey: id) != nil
    }

    /// Drops every resident that cannot run on `installedBase`. Returns what went, sorted
    /// so the caller's logs and the tests see a stable order.
    @discardableResult
    public mutating func evictIncompatible(with installedBase: BaseModelVersion) -> [AdapterIdentifier] {
        let doomed = residents.values
            .filter { !$0.descriptor.compatibility.contains(installedBase) }
            .map(\.descriptor.id)
            .sorted()
        for id in doomed { residents.removeValue(forKey: id) }
        return doomed
    }

    // MARK: - Private

    private mutating func insert(_ descriptor: AdapterDescriptor) {
        residents[descriptor.id] = Resident(
            descriptor: descriptor,
            lastAccessTick: nextTick(),
            isPinned: false
        )
    }

    private mutating func nextTick() -> UInt64 {
        // Wrapping is the correct choice over trapping: at one touch per microsecond this
        // wraps after roughly 584,000 years, and a trap here would crash the app.
        tick &+= 1
        return tick
    }

    private func nextEvictionVictim(installedBase: BaseModelVersion) -> AdapterIdentifier? {
        let evictable = residents.values.filter {
            $0.descriptor.consumesManagedStorage && !$0.isPinned
        }
        guard !evictable.isEmpty else { return nil }

        let incompatible = evictable.filter { !$0.descriptor.compatibility.contains(installedBase) }
        let pool = incompatible.isEmpty ? evictable : incompatible
        // `pool` is non-empty on both branches, so `min(by:)` returns a value; the
        // optional is unwrapped with `?.` rather than `!` regardless.
        return pool.min { lhs, rhs in
            if lhs.lastAccessTick != rhs.lastAccessTick {
                return lhs.lastAccessTick < rhs.lastAccessTick
            }
            return lhs.descriptor.id < rhs.descriptor.id
        }?.descriptor.id
    }
}
