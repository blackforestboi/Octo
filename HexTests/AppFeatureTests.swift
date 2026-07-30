import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Octo

@MainActor
final class AppFeatureTests: XCTestCase {
	func testSpeakersTabCanBeSelected() async {
		let store = TestStore(initialState: AppFeature.State()) {
			AppFeature()
		}

		await store.send(.setActiveTab(.speakers)) {
			$0.activeTab = .speakers
		}
	}

	func testHandoffsTabCanBeSelected() async {
		let store = TestStore(initialState: AppFeature.State()) {
			AppFeature()
		}

		await store.send(.setActiveTab(.handoffs)) {
			$0.activeTab = .handoffs
		}
	}

	func testSupportTabCanBeSelected() async {
		let store = TestStore(initialState: AppFeature.State()) {
			AppFeature()
		}

		await store.send(.setActiveTab(.support)) {
			$0.activeTab = .support
		}
	}

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

	func testRecoveredSystemAudioAttachesToItsMicrophoneHistoryEntry() async {
		let parentSessionID = UUID()
		let microphoneURL = RecordingRecoveryStore.finalAudioURL(for: parentSessionID)
		let systemAudioURL = URL(fileURLWithPath: "/recovered-system-audio.caf")
		let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
		let state = AppFeature.State()
		state.history.$transcriptionHistory.withLock { history in
			history.history = [
				Transcript(
					timestamp: startedAt,
					text: "",
					audioPath: microphoneURL,
					duration: 4,
					status: .processing,
					audioChannels: [
						.init(source: .microphone, audioPath: microphoneURL, duration: 4)
					]
				)
			]
		}

		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.recording = RecordingClient()
			$0.systemAudioCapture = SystemAudioCaptureClient()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.interruptedRecordingsRecovered(
			[],
			[
				.init(
					captureID: UUID(),
					parentRecordingSessionID: parentSessionID,
					createdAt: startedAt.addingTimeInterval(0.25),
					audioURL: systemAudioURL,
					duration: 3.5
				)
			]
		))
		await store.finish()

		guard let transcript = store.state.history.transcriptionHistory.history.first,
			let systemChannel = transcript.audioChannels?.first(where: { $0.source == .systemAudio })
		else {
			return XCTFail("Expected the recovered system-audio channel in History")
		}
		XCTAssertEqual(systemChannel.audioPath, systemAudioURL)
		XCTAssertEqual(systemChannel.duration, 3.5)
		XCTAssertEqual(systemChannel.startOffset, 0.25, accuracy: 0.001)
		XCTAssertEqual(transcript.status, .failed)
	}
}

private actor PasteProbe {
	private(set) var value: String?

	func record(_ value: String) {
		self.value = value
	}
}
