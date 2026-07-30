import Foundation
import XCTest

@testable import Octo

final class AgentHandoffClientTests: XCTestCase {
	func testCodexThreadDestinationUsesTheDesktopThreadRoute() {
		let id = "528b9ff2-d685-4c1a-b2d8-76d6a1661de3"

		let url = AgentHandoffThreadDestination.codexURL(for: id)

		XCTAssertEqual(url?.absoluteString, "codex://threads/\(id)")
	}

	func testCodexThreadDestinationRejectsMalformedThreadIDs() {
		XCTAssertNil(AgentHandoffThreadDestination.codexURL(for: "not-a-thread"))
	}

	func testHandoffTaskIsOpenableOnlyWithANativeThread() {
		let task = AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Update menu bar",
			state: .pending,
			thread: .codex("528b9ff2-d685-4c1a-b2d8-76d6a1661de3"),
			handoff: ""
		)
		let legacyTask = AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Legacy handoff",
			state: .pending,
			thread: nil,
			handoff: ""
		)

		XCTAssertTrue(task.isOpenable)
		XCTAssertFalse(legacyTask.isOpenable)
	}

	func testHandoffTaskExposesLifecycleStateForMenuBarStatus() {
		let runningTask = AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Update menu bar",
			state: .running,
			thread: .codex("528b9ff2-d685-4c1a-b2d8-76d6a1661de3"),
			handoff: ""
		)
		let completedTask = AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Finish menu bar",
			state: .completed,
			thread: .codex("528b9ff2-d685-4c1a-b2d8-76d6a1661de3"),
			handoff: ""
		)

		XCTAssertTrue(runningTask.isRunning)
		XCTAssertFalse(runningTask.isCompleted)
		XCTAssertTrue(completedTask.isCompleted)
		XCTAssertFalse(completedTask.isRunning)
	}
}
