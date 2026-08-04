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

        let future = Fixture.descriptor(
            "future", megabytes: 40,
            distribution: .remote(locator: "https://example.invalid/f")
        )
        let outdated = AdapterDescriptor(
            id: AdapterIdentifier("outdated"), task: Fixture.summarise, revision: 1,
            compatibility: BaseModelWindow(from: BaseModelVersion(28, 0, 0), upTo: BaseModelVersion(29, 0, 0)),
            payloadBytes: 40 * Fixture.megabyte,
            distribution: .remote(locator: "https://example.invalid/o")
        )
        _ = future
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
        XCTAssertEqual(available, 100 * Fixture.megabyte)
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

    func testPinExclusivelyProtectsOnlyTheServingAdapter() {
        var store = storage(megabytes: 200)
        _ = store.admit(Fixture.descriptor("a", megabytes: 10), installedBase: Fixture.base27)
        _ = store.admit(Fixture.descriptor("b", megabytes: 10), installedBase: Fixture.base27)
        store.setPinned(true, for: AdapterIdentifier("a"))
        store.pinExclusively(AdapterIdentifier("b"))
        XCTAssertEqual(store.resident(AdapterIdentifier("a"))?.isPinned, false)
        XCTAssertEqual(store.resident(AdapterIdentifier("b"))?.isPinned, true)
        store.pinExclusively(nil)
        XCTAssertEqual(store.resident(AdapterIdentifier("b"))?.isPinned, false)
    }

    /// Bundled artifacts already cost app size; evicting one frees nothing, so counting
    /// them against the download budget would make the budget describe the wrong thing.
    func testBundledArtifactsDoNotConsumeTheManagedBudget() {
        var store = storage(megabytes: 50)
        let bundled = Fixture.descriptor("bundled", megabytes: 300, distribution: .bundled)
        XCTAssertEqual(store.admit(bundled, installedBase: Fixture.base27), .admitted(evicted: []))
        XCTAssertEqual(store.usedBytes, 0)
        XCTAssertEqual(store.admit(Fixture.descriptor("remote", megabytes: 50), installedBase: Fixture.base27),
                       .admitted(evicted: []))
        XCTAssertTrue(store.isResident(AdapterIdentifier("bundled")), "bundled artifacts are not eviction candidates")
    }

    func testEvictIncompatibleClearsExactlyTheUnusableOnes() {
        var store = storage(megabytes: 300)
        _ = store.admit(Fixture.descriptor("gen27", window: Fixture.oneGeneration, megabytes: 10), installedBase: Fixture.base27)
        _ = store.admit(Fixture.descriptor("openEnded", window: BaseModelWindow(from: Fixture.base27), megabytes: 10), installedBase: Fixture.base27)
        _ = store.admit(Fixture.descriptor("narrow", window: BaseModelWindow(from: Fixture.base27, upTo: Fixture.base271), megabytes: 10), installedBase: Fixture.base27)

        let evicted = store.evictIncompatible(with: Fixture.base272)
        XCTAssertEqual(evicted, [AdapterIdentifier("gen27"), AdapterIdentifier("narrow")], "sorted, and only the unusable ones")
        XCTAssertEqual(store.residentIdentifiers, [AdapterIdentifier("openEnded")])
    }

    func testCandidatesAreOrderedByRevisionThenIdentifier() {
        var store = storage(megabytes: 300)
        _ = store.admit(Fixture.descriptor("b", revision: 2, megabytes: 5), installedBase: Fixture.base27)
        _ = store.admit(Fixture.descriptor("a", revision: 2, megabytes: 5), installedBase: Fixture.base27)
        _ = store.admit(Fixture.descriptor("c", revision: 7, megabytes: 5), installedBase: Fixture.base27)
        _ = store.admit(Fixture.descriptor("z", task: Fixture.rewriteTone, revision: 9, megabytes: 5), installedBase: Fixture.base27)

        XCTAssertEqual(
            store.candidates(for: Fixture.summarise).map(\.id),
            [AdapterIdentifier("c"), AdapterIdentifier("a"), AdapterIdentifier("b")]
        )
        XCTAssertEqual(store.candidates(for: Fixture.rewriteTone).map(\.id), [AdapterIdentifier("z")])
    }

    func testDegenerateInputsDoNotTrap() {
        var zeroBudget = AdapterStorage(budgetBytes: 0)
        XCTAssertEqual(zeroBudget.utilisationPercent, 0, "must not divide by a zero budget")
        XCTAssertEqual(zeroBudget.usedBytes, 0)
        guard case .rejectedExceedsBudget = zeroBudget.admit(Fixture.descriptor("a", megabytes: 1), installedBase: Fixture.base27) else {
            return XCTFail("a zero budget cannot admit anything")
        }

        var negativeBudget = AdapterStorage(budgetBytes: -5_000)
        XCTAssertEqual(negativeBudget.budgetBytes, 0)
        XCTAssertEqual(negativeBudget.utilisationPercent, 0)
        XCTAssertFalse(negativeBudget.evict(AdapterIdentifier("nothing")))
        negativeBudget.touch(AdapterIdentifier("nothing"))
        negativeBudget.setPinned(true, for: AdapterIdentifier("nothing"))
        XCTAssertTrue(negativeBudget.residentIdentifiers.isEmpty)
        XCTAssertTrue(negativeBudget.candidates(for: Fixture.summarise).isEmpty)
        XCTAssertNil(negativeBudget.resident(AdapterIdentifier("nothing")))
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
