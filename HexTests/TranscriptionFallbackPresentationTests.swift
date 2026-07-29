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
