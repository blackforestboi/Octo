import XCTest

@testable import Octo

final class MenuBarHandoffStatusIconTests: XCTestCase {
	func testRunningHandoffsActivateTheSpinningIcon() {
		XCTAssertTrue(MenuBarHandoffStatus.running.isSpinning)
	}

	func testIdleAndCompletedHandoffsStopTheSpinningIcon() {
		XCTAssertFalse(MenuBarHandoffStatus.idle.isSpinning)
		XCTAssertFalse(MenuBarHandoffStatus.completed.isSpinning)
	}
}
