import XCTest
@testable import ConfigDeck

final class UpdateCheckerTests: XCTestCase {

    func testNewerVersionDetected() {
        XCTAssertTrue(UpdateChecker.isNewer(latest: "v0.1.3", current: "0.1.2"))
    }

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(latest: "v0.1.2", current: "0.1.2"))
    }

    /// Dev builds can run ahead of the latest release — no downgrade banner.
    func testOlderVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(latest: "v0.1.1", current: "0.1.2"))
    }

    /// Numeric comparison, not lexicographic: "0.1.10" > "0.1.2".
    func testMultiDigitComponentComparesNumerically() {
        XCTAssertTrue(UpdateChecker.isNewer(latest: "v0.1.10", current: "0.1.2"))
        XCTAssertFalse(UpdateChecker.isNewer(latest: "v0.1.2", current: "0.1.10"))
    }

    func testMinorAndMajorBumps() {
        XCTAssertTrue(UpdateChecker.isNewer(latest: "v0.2.0", current: "0.1.9"))
        XCTAssertTrue(UpdateChecker.isNewer(latest: "v1.0.0", current: "0.9.9"))
    }
}
