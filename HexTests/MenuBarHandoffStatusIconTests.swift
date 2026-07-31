import AppKit
import XCTest

@testable import Octo

@MainActor
final class MenuBarHandoffStatusIconTests: XCTestCase {
	func testStatusButtonFrameUsesGlobalScreenCoordinates() {
		let window = NSWindow(
			contentRect: NSRect(x: 240, y: 180, width: 320, height: 80),
			styleMask: .borderless,
			backing: .buffered,
			defer: false
		)
		let button = NSStatusBarButton(frame: NSRect(x: 34, y: 12, width: 28, height: 24))
		window.contentView?.addSubview(button)

		let expected = window.convertToScreen(button.convert(button.bounds, to: nil))

		XCTAssertEqual(MenuBarStatusItemController.screenFrame(for: button), expected)
	}

	func testStatusButtonWithoutWindowHasNoScreenFrame() {
		let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))

		XCTAssertNil(MenuBarStatusItemController.screenFrame(for: button))
	}

	func testHandoffDestinationUsesStatusButtonCenter() {
		let statusFrame = NSRect(x: 1_420, y: 1_052, width: 28, height: 24)

		let destination = InvisibleWindow.agentHandoffDestination(
			statusItemFrame: statusFrame,
			fallbackScreenFrame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
			statusBarHeight: 24
		)

		XCTAssertEqual(destination, NSPoint(x: statusFrame.midX, y: statusFrame.midY))
	}

	func testRunningHandoffsActivateTheSpinningIcon() {
		XCTAssertTrue(MenuBarHandoffStatus.running.isSpinning)
	}

	func testRegisteredHandoffDoesNotCountAsRunningMenuBarActivity() {
		XCTAssertEqual(MenuBarHandoffStatus.status(for: [handoffTask(state: .registered)]), .idle)
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

	func testWaitingHandoffSummaryUsesSingularTaskLabel() {
		XCTAssertEqual(
			MenuBarHandoffProcessingRow.waitingLabel(forPendingJobCount: 1),
			"Waiting for 1 task"
		)
	}

	func testWaitingHandoffSummaryCountsPendingJobsAndUsesPluralTaskLabel() {
		XCTAssertEqual(
			MenuBarHandoffProcessingRow.waitingLabel(forPendingJobCount: 3),
			"Waiting for 3 tasks"
		)
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
