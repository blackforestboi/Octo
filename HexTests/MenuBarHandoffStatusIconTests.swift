import AppKit
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

	func testCompletedHandoffTakesPrecedenceOverAnotherRunningHandoff() {
		let runningTask = handoffTask(state: .running)
		let completedTask = handoffTask(state: .completed)

		XCTAssertEqual(MenuBarHandoffStatus.status(for: [runningTask, completedTask]), .completed)
	}

	func testAcknowledgedCompletionDoesNotKeepTheMenuBarInUpdateState() {
		let completedTask = handoffTask(state: .completed, isCompletionAcknowledged: true)

		XCTAssertEqual(MenuBarHandoffStatus.status(for: [completedTask]), .idle)
	}

	func testCompletedIndicatorsUseNonTemplateImages() {
		XCTAssertFalse(AgentHandoffStatusImages.completedDot.isTemplate)
		XCTAssertFalse(AgentHandoffStatusImages.blueIcon(from: NSImage(size: .init(width: 18, height: 18))).isTemplate)
	}

	func testDefaultMenuBarIconUsesTemplateRendering() {
		XCTAssertTrue(AgentHandoffStatusImages.templateIcon(from: NSImage(size: .init(width: 18, height: 18))).isTemplate)
	}

	private func handoffTask(
		state: AgentHandoffTask.Status,
		isCompletionAcknowledged: Bool = false
	) -> AgentHandoffTask {
		AgentHandoffTask(
			id: UUID(),
			createdAt: .now,
			provider: .codex,
			title: "Update menu bar",
			state: state,
			thread: .codex("528b9ff2-d685-4c1a-b2d8-76d6a1661de3"),
			handoff: "",
			isCompletionAcknowledged: isCompletionAcknowledged
		)
	}
}
