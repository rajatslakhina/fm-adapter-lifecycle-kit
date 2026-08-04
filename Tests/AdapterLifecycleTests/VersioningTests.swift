import XCTest
@testable import AdapterLifecycle

final class VersioningTests: XCTestCase {

    func testParsesOneTwoAndThreeFieldVersions() throws {
        XCTAssertEqual(BaseModelVersion(parsing: "27"), BaseModelVersion(27, 0, 0))
        XCTAssertEqual(BaseModelVersion(parsing: "27.1"), BaseModelVersion(27, 1, 0))
        XCTAssertEqual(BaseModelVersion(parsing: "27.1.3"), BaseModelVersion(27, 1, 3))
    }

    func testRejectsMalformedVersionsInsteadOfGuessing() {
        XCTAssertNil(BaseModelVersion(parsing: ""))
        XCTAssertNil(BaseModelVersion(parsing: "27.1.3.4"))
        XCTAssertNil(BaseModelVersion(parsing: "27..3"))
        XCTAssertNil(BaseModelVersion(parsing: "twenty-seven"))
        XCTAssertNil(BaseModelVersion(parsing: "-1.0.0"))
        XCTAssertNil(BaseModelVersion(parsing: "27.1.x"))
        // Larger than Int64. `Int(_:)` returns nil rather than trapping, which is the
        // whole reason parsing goes through it.
        XCTAssertNil(BaseModelVersion(parsing: "99999999999999999999999"))
    }

    func testNegativeComponentsClampRatherThanSortAboveRealVersions() {
        let clamped = BaseModelVersion(-4, -9, -1)
        XCTAssertEqual(clamped, BaseModelVersion(0, 0, 0))
        XCTAssertLessThan(clamped, BaseModelVersion(27, 0, 0))
    }

    func testOrderingIsLexicographicByComponent() {
        XCTAssertLessThan(BaseModelVersion(27, 0, 0), BaseModelVersion(27, 0, 1))
        XCTAssertLessThan(BaseModelVersion(27, 0, 9), BaseModelVersion(27, 1, 0))
        XCTAssertLessThan(BaseModelVersion(27, 9, 9), BaseModelVersion(28, 0, 0))
        XCTAssertEqual(BaseModelVersion(27, 1, 0), BaseModelVersion(parsing: "27.1"))
    }

    func testWindowIsHalfOpen() {
        let window = BaseModelWindow(from: BaseModelVersion(27, 0, 0), upTo: BaseModelVersion(27, 2, 0))
        XCTAssertTrue(window.contains(BaseModelVersion(27, 0, 0)))
        XCTAssertTrue(window.contains(BaseModelVersion(27, 1, 9)))
        XCTAssertFalse(window.contains(BaseModelVersion(27, 2, 0)), "upper bound is exclusive")
        XCTAssertFalse(window.contains(BaseModelVersion(26, 9, 9)))
    }

    func testWindowReportsDirectionOfIncompatibility() {
        let window = BaseModelWindow(from: BaseModelVersion(27, 0, 0), upTo: BaseModelVersion(27, 2, 0))
        XCTAssertEqual(window.relation(to: BaseModelVersion(26, 5, 0)), .installedTooOld)
        XCTAssertEqual(window.relation(to: BaseModelVersion(27, 1, 0)), .satisfied)
        XCTAssertEqual(window.relation(to: BaseModelVersion(27, 2, 0)), .installedTooNew)
    }

    func testOpenEndedWindowAcceptsEverythingAtOrAboveLowerBound() {
        let window = BaseModelWindow(from: BaseModelVersion(27, 0, 0))
        XCTAssertFalse(window.isEmpty)
        XCTAssertTrue(window.contains(BaseModelVersion(99, 0, 0)))
        XCTAssertFalse(window.contains(BaseModelVersion(26, 9, 9)))
    }

    /// A window built from a bad remote config must fail closed — every version reads as
    /// too new, so resolution falls back to the base model rather than serving anything.
    func testInvertedWindowIsEmptyAndAcceptsNothing() {
        let window = BaseModelWindow(from: BaseModelVersion(28, 0, 0), upTo: BaseModelVersion(27, 0, 0))
        XCTAssertTrue(window.isEmpty)
        XCTAssertFalse(window.contains(BaseModelVersion(27, 5, 0)))
        XCTAssertFalse(window.contains(BaseModelVersion(28, 0, 0)))
        XCTAssertFalse(window.contains(BaseModelVersion(29, 0, 0)))
    }
}
