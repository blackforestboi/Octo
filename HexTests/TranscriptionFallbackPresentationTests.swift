import ComposableArchitecture
import XCTest

@testable import Octo

@MainActor
final class TranscriptionFallbackPresentationTests: XCTestCase {
	func testKnownMissingDestinationShowsTranscriptInsteadOfPasting() async {
		let probe = ClipboardProbe()
		let store = TestStore(initialState: TranscriptionFeature.State()) {
			TranscriptionFeature()
		} withDependencies: {
			$0.pasteboard.focusedEditableDestination = { .absent }
			$0.pasteboard.paste = { text in await probe.recordPaste(text) }
		}

		await store.send(.pasteCompletedTranscript("Transcript ready to copy"))
		await store.receive(\.showCompletedTranscript) {
			$0.completedTranscriptPresentation = .expanded("Transcript ready to copy")
		}
		await store.finish()

		let pastedText = await probe.pastedText
		XCTAssertNil(pastedText)
	}

	func testIndeterminateDestinationShowsTranscriptInsteadOfPasting() async {
		let probe = ClipboardProbe()
		let store = TestStore(initialState: TranscriptionFeature.State()) {
			TranscriptionFeature()
		} withDependencies: {
			$0.pasteboard.focusedEditableDestination = { .indeterminate }
			$0.pasteboard.paste = { text in await probe.recordPaste(text) }
		}

		await store.send(.pasteCompletedTranscript("Keep transcript when focus is uncertain"))
		await store.receive(\.showCompletedTranscript) {
			$0.completedTranscriptPresentation = .expanded("Keep transcript when focus is uncertain")
		}
		await store.finish()

		let pastedText = await probe.pastedText
		XCTAssertNil(pastedText)
	}

	func testCopyShowsConfirmationThenHidesAfterTwoSeconds() async {
		let clock = TestClock()
		let probe = ClipboardProbe()
		var state = TranscriptionFeature.State()
		state.completedTranscriptPresentation = .expanded("Copy this text")
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.pasteboard.copy = { text in await probe.recordCopy(text) }
		}

		await store.send(.copyCompletedTranscript) {
			$0.completedTranscriptPresentation = .copied("Copy this text")
		}
		await clock.advance(by: .seconds(2))
		await store.receive(\.completedTranscriptPresentationExpired) {
			$0.completedTranscriptPresentation = .hidingCopied("Copy this text")
		}
		await clock.advance(by: .milliseconds(220))
		await store.receive(\.completedTranscriptPresentationDismissalFinished) {
			$0.completedTranscriptPresentation = nil
		}
		await store.finish()

		let copiedText = await probe.copiedText
		XCTAssertEqual(copiedText, "Copy this text")
	}

	func testDismissClosesWithoutCopying() async {
		let probe = ClipboardProbe()
		var state = TranscriptionFeature.State()
		state.completedTranscriptPresentation = .expanded("Do not copy")
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.pasteboard.copy = { text in await probe.recordCopy(text) }
		}

		await store.send(.dismissCompletedTranscript) {
			$0.completedTranscriptPresentation = nil
		}
		await store.finish()

		let copiedText = await probe.copiedText
		XCTAssertNil(copiedText)
	}

	func testEscapeDismissesAnExpandedTranscript() async {
		var state = TranscriptionFeature.State()
		state.completedTranscriptPresentation = .expanded("Dismiss with Escape")
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		}

		await store.send(.cancel)
		await store.receive(\.dismissCompletedTranscript) {
			$0.completedTranscriptPresentation = nil
		}
		await store.finish()
	}

	func testEscapeDismissesReadyAgentHandoff() async {
		var state = TranscriptionFeature.State()
		state.agentHandoffPresentation = .init(label: "Tasks created", isReady: true)
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		}

		await store.send(.cancel)
		await store.receive(\.dismissAgentHandoff) {
			$0.agentHandoffPresentation = nil
		}
		await store.finish()
	}

	func testHandoffPillDepartsWhenCoordinatorIsSubmittedAndWaitingRowEndsAtFirstTask() async {
		let clock = TestClock()
		let handoffID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
		var state = TranscriptionFeature.State()
		state.agentHandoffPresentation = .init(
			handoffID: handoffID,
			label: "Processing"
		)
		state.agentHandoffProcessingStatuses.append(.init(
			id: handoffID,
			provider: .codex,
			label: "Starting coordinator"
		))
		state.agentHandoffActiveThreads[handoffID] = []
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.continuousClock = clock
		}

		await store.send(.agentHandoffEvent(handoffID, .coordinatorSubmitted)) {
			$0.agentHandoffProcessingStatuses[id: handoffID]?.label = "Waiting for tasks"
			$0.agentHandoffPresentation?.hasLaunched = true
			$0.agentHandoffPresentation?.isReady = true
			$0.agentHandoffPresentation?.isDeparting = true
		}
		await store.receive(\.agentHandoffPresentationExpired)
		await store.send(.agentHandoffEvent(handoffID, .tasksFound(2))) {
			$0.agentHandoffProcessingStatuses[id: handoffID]?.expectedTaskCount = 2
		}
		await store.send(.agentHandoffEvent(handoffID, .childStarted(.codex("first"), ordinal: 1))) {
			$0.agentHandoffActiveThreads[handoffID] = [.codex("first")]
			$0.agentHandoffProcessingStatuses.remove(id: handoffID)
		}
		await clock.advance(by: .milliseconds(320))
		await store.receive(\.agentHandoffCollapseFinished) {
			$0.agentHandoffPresentation?.isFlying = true
		}
		await clock.advance(by: .milliseconds(820))
		await store.receive(\.agentHandoffDepartureFinished) {
			$0.agentHandoffPresentation = nil
		}
		await store.send(.agentHandoffEvent(handoffID, .completed)) {
			$0.agentHandoffActiveThreads.removeValue(forKey: handoffID)
		}
		await store.finish()
	}

	func testConcurrentHandoffProgressIsTrackedIndependently() async {
		let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
		let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
		var state = TranscriptionFeature.State()
		state.agentHandoffProcessingStatuses = [
			.init(id: firstID, provider: .codex, label: "Preparing agent handoff"),
			.init(id: secondID, provider: .claude, label: "Preparing agent handoff"),
		]
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		}

		await store.send(.agentHandoffEvent(firstID, .processing)) {
			$0.agentHandoffProcessingStatuses[id: firstID]?.label = "Starting coordinator"
		}
		await store.send(.agentHandoffEvent(firstID, .completed)) {
			$0.agentHandoffProcessingStatuses.remove(id: firstID)
		}
		await store.finish()
	}

	#if DEBUG
	func testDebugHandoffAnimationRunsTheProductionDepartureSequence() async {
		let clock = TestClock()
		let handoffID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
		let store = TestStore(initialState: TranscriptionFeature.State()) {
			TranscriptionFeature()
		} withDependencies: {
			$0.continuousClock = clock
		}

		await store.send(.debugAgentHandoffAnimation) {
			$0.agentHandoffProcessingStatuses.append(.init(
				id: handoffID,
				provider: .codex,
				label: "Starting coordinator"
			))
			$0.agentHandoffPresentation = .init(
				handoffID: handoffID,
				label: "Processing"
			)
		}
		await clock.advance(by: .milliseconds(300))
		await store.receive(\.agentHandoffEvent) {
			$0.agentHandoffProcessingStatuses[id: handoffID]?.label = "Waiting for tasks"
			$0.agentHandoffPresentation?.hasLaunched = true
			$0.agentHandoffPresentation?.isReady = true
			$0.agentHandoffPresentation?.isDeparting = true
		}
		await store.receive(\.agentHandoffPresentationExpired)
		await clock.advance(by: .milliseconds(320))
		await store.receive(\.agentHandoffCollapseFinished) {
			$0.agentHandoffPresentation?.isFlying = true
		}
		await clock.advance(by: .milliseconds(380))
		await store.receive(\.agentHandoffEvent) {
			$0.agentHandoffProcessingStatuses[id: handoffID]?.expectedTaskCount = 2
		}
		await clock.advance(by: .milliseconds(440))
		await store.receive(\.agentHandoffDepartureFinished) {
			$0.agentHandoffPresentation = nil
		}
		await clock.advance(by: .milliseconds(210))
		await store.receive(\.agentHandoffEvent) {
			$0.agentHandoffProcessingStatuses.remove(id: handoffID)
		}
		await store.finish()
	}
	#endif
}

private actor ClipboardProbe {
	private(set) var pastedText: String?
	private(set) var copiedText: String?

	func recordPaste(_ text: String) {
		pastedText = text
	}

	func recordCopy(_ text: String) {
		copiedText = text
	}
}
