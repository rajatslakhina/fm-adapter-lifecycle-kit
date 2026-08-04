import XCTest
@testable import AdapterLifecycle

final class AdapterStorageTests: XCTestCase {

    private func storage(megabytes: Int) -> AdapterStorage {
        AdapterStorage(budgetBytes: megabytes * Fixture.megabyte)
    }

    func testAdmitsWhatFitsAndAccountsForIt() {
        var store = storage(megabytes: 100)
        let outcome = store.admit(Fixture.descriptor("a", megabytes: 40), installedBase: Fixture.base27)
        XCTAssertEqual(outcome, .admitted(evicted: []))
        XCTAssertEqual(store.usedBytes, 40 * Fixture.megabyte)
        XCTAssertEqual(store.availableBytes, 60 * Fixture.megabyte)
        XCTAssertEqual(store.utilisationPercent, 40)
    }

    func testReAdmittingAResidentIsIdempotent() {
        var store = storage(megabytes: 100)
        let descriptor = Fixture.descriptor("a", megabytes: 40)
        _ = store.admit(descriptor, installedBase: Fixture.base27)
        XCTAssertEqual(store.admit(descriptor, installedBase: Fixture.base27), .alreadyResident)
        XCTAssertEqual(store.usedBytes, 40 * Fixture.megabyte, "must not double-count")
    }

    /// Refusing before spending a byte. Caching an artifact that cannot run on the
    /// installed base model is pure waste, and doing it under storage pressure means
    /// evicting something useful to make room for something unusable.
    func testRefusesIncompatibleArtifactsWithoutEvictingAnything() {
        var store = storage(megabytes: 100)
        _ = store.admit(Fixture.descriptor("keep", megabytes: 40), installedBase: Fixture.base27)

        let outdated = AdapterDescriptor(
            id: AdapterIdentifier("outdated"), task: Fixture.summarise, revision: 1,
            compatibility: BaseModelWindow(from: BaseModelVersion(28, 0, 0), upTo: BaseModelVersion(29, 0, 0)),
            payloadBytes: 40 * Fixture.megabyte,
            distribution: .remote(locator: "https://example.invalid/o")
        )
        let outcome = store.admit(outdated, installedBase: Fixture.base27)
        guard case .rejectedIncompatible = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(store.isResident(AdapterIdentifier("keep")))
        XCTAssertEqual(store.usedBytes, 40 * Fixture.megabyte)
    }

    func testAnArtifactLargerThanTheWholeBudgetIsRefusedWithoutEviction() {
        var store = storage(megabytes: 100)
        _ = store.admit(Fixture.descriptor("keep", megabytes: 40), installedBase: Fixture.base27)
        let outcome = store.admit(Fixture.descriptor("whale", megabytes: 400), installedBase: Fixture.base27)
        guard case let .rejectedExceedsBudget(payload, available) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(payload, 400 * Fixture.megabyte)
        // The free space, not the whole budget: 40 MB of the 100 MB budget is already in
        // use, so "will not fit in 100 MB" would be a misleading thing to log.
        XCTAssertEqual(available, 60 * Fixture.megabyte)
        XCTAssertTrue(store.isResident(AdapterIdentifier("keep")), "nothing should have been evicted for a lost cause")
    }

    func testEvictsLeastRecentlyUsedToMakeRoom() {
        var store = storage(megabytes: 100)
        _ = store.admit(Fixture.descriptor("cold", megabytes: 40), installedBase: Fixture.base27)
        _ = store.admit(Fixture.descriptor("warm", megabytes: 40), installedBase: Fixture.base27)
        store.touch(AdapterIdentifier("warm"))

        let outcome = store.admit(Fixture.descriptor("new", megabytes: 40), installedBase: Fixture.base27)
        XCTAssertEqual(outcome, .admitted(evicted: [AdapterIdentifier("cold")]))
        XCTAssertFalse(store.isResident(AdapterIdentifier("cold")))
        XCTAssertTrue(store.isResident(AdapterIdentifier("warm")))
        XCTAssertTrue(store.isResident(AdapterIdentifier("new")))
    }

    /// Incompatible residents are dead weight and go before anything still usable, even
    /// when the usable one is colder.
    func testIncompatibleResidentsAreEvictedBeforeColdCompatibleOnes() {
        var store = storage(megabytes: 100)
        let stale = AdapterDescriptor(
            id: AdapterIdentifier("stale"), task: Fixture.summarise, revision: 1,
            compatibility: BaseModelWindow(from: Fixture.base27, upTo: Fixture.base271),
            payloadBytes: 40 * Fixture.megabyte,
            distribution: .remote(locator: "https://example.invalid/s")
        )
        // Admitted while it was still compatible.
        XCTAssertEqual(store.admit(stale, installedBase: Fixture.base27), .admitted(evicted: []))
        _ = store.admit(Fixture.descriptor("cold", megabytes: 40), installedBase: Fixture.base27)
        // `stale` is now the *most* recently used, so pure LRU would evict "cold".
        store.touch(AdapterIdentifier("stale"))

        let outcome = store.admit(
            Fixture.descriptor("new", window: BaseModelWindow(from: Fixture.base27), megabytes: 40),
            installedBase: Fixture.base271
        )
        XCTAssertEqual(outcome, .admitted(evicted: [AdapterIdentifier("stale")]))
        XCTAssertTrue(store.isResident(AdapterIdentifier("cold")), "a usable cold artifact outranks an unusable warm one")
    }

    func testPinnedResidentsAreNeverEvicted() {
        var store = storage(megabytes: 100)
        _ = store.admit(Fixture.descriptor("serving", megabytes: 60), installedBase: Fixture.base27)
        store.setPinned(true, for: AdapterIdentifier("serving"))

        let outcome = store.admit(Fixture.descriptor("new", megabytes: 60), installedBase: Fixture.base27)
        guard case .rejectedExceedsBudget = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(store.isResident(AdapterIdentifier("serving")), "the model in active use must survive")
    }

    /// The pin set is a set, not a single identifier. An app with two tasks has two
    /// adapters serving at once, and an earlier version of this API took one id — which
    /// meant protecting task B's adapter silently exposed task A's to eviction.
    func testSetPinnedExactlyProtectsEveryServingAdapterAtOnce() {
        var store = storage(megabytes: 200)
        _ = store.admit(Fixture.descriptor("a", megabytes: 10), installedBase: Fixture.base27)
        _ = store.admit(Fixture.descriptor("b", megabytes: 10), installedBase: Fixture.base27)
        _ = store.admit(Fixture.descriptor("c", megabytes: 10), installedBase: Fixture.base27)

        store.setPinned(exactly: [AdapterIdentifier("a"), AdapterIdentifier("b")])
        XCTAssertEqual(store.resident(AdapterIdentifier("a"))?.isPinned, true)
        XCTAssertEqual(store.resident(AdapterIdentifier("b"))?.isPinned, true)
        XCTAssertEqual(store.resident(AdapterIdentifier("c"))?.isPinned, false)

        store.setPinned(exactly: [AdapterIdentifier("c")])
        XCTAssertEqual(store.resident(AdapterIdentifier("a"))?.isPinned, false)
        XCTAssertEqual(store.resident(AdapterIdentifier("c"))?.isPinned, true)

        store.setPinned(exactly: [])
        XCTAssertEqual(store.resident(AdapterIdentifier("c"))?.isPinned, false)
    }

    /// Bytes alone do not bound the resident set: bundled artifacts skip the budget
    /// entirely and a zero-byte remote artifact never moves `usedBytes`, so without a
    /// count ceiling the cache grows without limit while looking empty.
    func testResidentCountIsBoundedEvenWhenNothingConsumesBytes() {
        var store = AdapterStorage(budgetBytes: 100 * Fixture.megabyte, maximumResidents: 3)
        for index in 0..<3 {
            let outcome = store.admit(
                Fixture.descriptor("bundled-\(index)", megabytes: 500, distribution: .bundled),
                installedBase: Fixture.base27
            )
            XCTAssertEqual(outcome, .admitted(evicted: []))
        }
        XCTAssertEqual(store.usedBytes, 0, "bundled artifacts consume no managed bytes")
        // Bundled artifacts are never evictable, so here the ceiling really is a wall and
        // refusing is the only honest answer.
        XCTAssertEqual(
            store.admit(Fixture.descriptor("bundled-3", megabytes: 500, distribution: .bundled), installedBase: Fixture.base27),
            .rejectedTooManyResidents(limit: 3)
        )
        XCTAssertEqual(store.residentIdentifiers.count, 3)
    }

    /// Count pressure evicts, exactly like byte pressure. Refusing outright would wedge
    /// the cache: once at the ceiling nothing could ever be admitted again, even with every
    /// resident cold and unpinned.
    func testCountPressureEvictsInsteadOfWedgingTheCache() {
        var store = AdapterStorage(budgetBytes: 100 * Fixture.megabyte, maximumResidents: 4)
        for index in 0..<4 {
            _ = store.admit(Fixture.descriptor("empty-\(index)", megabytes: 0), installedBase: Fixture.base27)
        }
        XCTAssertEqual(store.usedBytes, 0)
        XCTAssertEqual(store.residentIdentifiers.count, 4)

        let outcome = store.admit(Fixture.descriptor("empty-4", megabytes: 0), installedBase: Fixture.base27)
        XCTAssertEqual(outcome, .admitted(evicted: [AdapterIdentifier("empty-0")]), "the coldest goes")
        XCTAssertEqual(store.residentIdentifiers.count, 4, "and the ceiling still holds")
        XCTAssertTrue(store.isResident(AdapterIdentifier("empty-4")))
    }

    func testMaximumResidentsIsClampedToAtLeastOne() {
        var store = AdapterStorage(budgetBytes: 100 * Fixture.megabyte, maximumResidents: 0)
        XCTAssertEqual(store.maximumResidents, 1)
        XCTAssertEqual(store.admit(Fixture.descriptor("a", megabytes: 1), installedBase: Fixture.base27), .admitted(evicted: []))
        XCTAssertEqual(
            store.admit(Fixture.descriptor("b", megabytes: 1), installedBase: Fixture.base27),
            .admitted(evicted: [AdapterIdentifier("a")])
        )
        XCTAssertEqual(store.residentIdentifiers, [AdapterIdentifier("b")])
    }

    func testAZeroBytePayloadIsAdmittedRatherThanTrapping() {
        var store = storage(megabytes: 10)
        let empty = Fixture.descriptor("empty", megabytes: 0)
        XCTAssertEqual(store.admit(empty, installedBase: Fixture.base27), .admitted(evicted: []))
        XCTAssertEqual(store.usedBytes, 0)
    }

    func testNegativePayloadIsClampedSoItCannotInflateTheBudget() {
        let sneaky = AdapterDescriptor(
            id: AdapterIdentifier("sneaky"), task: Fixture.summarise, revision: 1,
            compatibility: Fixture.oneGeneration, payloadBytes: -1_000_000,
            distribution: .remote(locator: "https://example.invalid/x")
        )
        XCTAssertEqual(sneaky.payloadBytes, 0)
        var store = storage(megabytes: 10)
        _ = store.admit(sneaky, installedBase: Fixture.base27)
        XCTAssertEqual(store.usedBytes, 0)
        XCTAssertEqual(store.availableBytes, 10 * Fixture.megabyte)
    }
}
