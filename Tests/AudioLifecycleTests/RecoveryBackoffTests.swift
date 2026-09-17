import XCTest

@testable import AudioLifecycle

final class RecoveryBackoffTests: XCTestCase {
  func testDelayIncreasesToBoundAndResetStartsOver() {
    var recovery = RecoveryBackoff(initialDelay: 0.5, maximumDelay: 2)
    XCTAssertEqual((0..<5).map { _ in recovery.nextDelay() }, [0.5, 1, 2, 2, 2])
    XCTAssertEqual(recovery.attempt, 5)

    recovery.reset()

    XCTAssertEqual(recovery.attempt, 0)
    XCTAssertEqual(recovery.nextDelay(), 0.5)
  }
}
