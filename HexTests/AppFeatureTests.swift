import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Octo

@MainActor
final class AppFeatureTests: XCTestCase {
	func testPasteLastTranscriptPrefersMostRecentLiveTranscript() async {
		var state = AppFeature.State()
		state.transcription.recentCompletedTranscript = .init(
			id: UUID(),
			text: "new transcript",
			historyID: nil
		)
		state.transcription.$transcriptionHistory.withLock { history in
			history.history = [
				Transcript(
					timestamp: Date(timeIntervalSince1970: 1),
					text: "stale transcript",
					audioPath: URL(fileURLWithPath: "/stale.wav"),
					duration: 1
				)
			]
		}

		let probe = PasteProbe()
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.pasteboard.paste = { text in await probe.record(text) }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.pasteLastTranscript)
		await store.finish()

		let pastedText = await probe.value
		XCTAssertEqual(pastedText, "new transcript")
	}
}

private actor PasteProbe {
	private(set) var value: String?

	func record(_ value: String) {
		self.value = value
	}
}
