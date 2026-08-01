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

	func testSpeakerProfileFocusSelectsSpeakersAndClearsAfterLeavingTab() async {
		let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
		let store = TestStore(initialState: AppFeature.State()) {
			AppFeature()
		}

		await store.send(.focusSpeakerProfile(profileID)) {
			$0.activeTab = .speakers
			$0.speakerProfileIDToFocus = profileID
		}
		await store.send(.setActiveTab(.history)) {
			$0.activeTab = .history
			$0.speakerProfileIDToFocus = nil
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

	func testMicrophoneGrantUpdatesPermissionAndWarmsRecorder() async {
		let probe = MicrophonePermissionProbe()
		let store = TestStore(initialState: AppFeature.State()) {
			AppFeature()
		} withDependencies: {
			$0.permissions.requestMicrophone = {
				await probe.recordRequest()
				return true
			}
			$0.permissions.microphoneStatus = { .granted }
			$0.permissions.accessibilityStatus = { .granted }
			$0.permissions.inputMonitoringStatus = { .granted }
			$0.permissions.screenRecordingStatus = { false }
			$0.recording.warmUpRecorder = { await probe.recordWarmUp() }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.requestMicrophone))
		await store.receive(\.microphonePermissionRequestCompleted) {
			$0.microphonePermission = .granted
		}
		await store.receive(\.checkPermissions)
		await store.receive(\.permissionsUpdated) {
			$0.accessibilityPermission = .granted
			$0.inputMonitoringPermission = .granted
		}
		await store.finish()

		let counts = await probe.counts
		XCTAssertEqual(counts.requests, 1)
		XCTAssertEqual(counts.warmUps, 1)
		XCTAssertEqual(counts.settingsOpens, 0)
	}

	func testMicrophoneGrantRetriesNativeRequestWhenPermissionWasDenied() async {
		var state = AppFeature.State()
		state.microphonePermission = .denied
		let probe = MicrophonePermissionProbe()
		let store = TestStore(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.permissions.requestMicrophone = {
				await probe.recordRequest()
				return false
			}
			$0.permissions.microphoneStatus = { .denied }
			$0.permissions.accessibilityStatus = { .granted }
			$0.permissions.inputMonitoringStatus = { .granted }
			$0.permissions.screenRecordingStatus = { false }
			$0.permissions.openMicrophoneSettings = { await probe.recordSettingsOpen() }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.requestMicrophone))
		await store.receive(\.microphonePermissionRequestCompleted)
		await store.receive(\.checkPermissions)
		await store.receive(\.permissionsUpdated) {
			$0.accessibilityPermission = .granted
			$0.inputMonitoringPermission = .granted
		}
		await store.finish()

		let counts = await probe.counts
		XCTAssertEqual(counts.requests, 1)
		XCTAssertEqual(counts.warmUps, 0)
		XCTAssertEqual(counts.settingsOpens, 0)
	}

	func testMicrophoneStatusCheckDoesNotRequestNativePrompt() async {
		let probe = MicrophonePermissionProbe()
		let store = TestStore(initialState: AppFeature.State()) {
			AppFeature()
		} withDependencies: {
			$0.permissions.microphoneStatus = { .notDetermined }
			$0.permissions.accessibilityStatus = { .notDetermined }
			$0.permissions.inputMonitoringStatus = { .notDetermined }
			$0.permissions.screenRecordingStatus = { false }
			$0.permissions.requestMicrophone = {
				await probe.recordRequest()
				return false
			}
		}

		await store.send(.checkPermissions)
		await store.receive(\.permissionsUpdated)
		await store.finish()

		let counts = await probe.counts
		XCTAssertEqual(counts.requests, 0)
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

private actor MicrophonePermissionProbe {
	private var requestCount = 0
	private var warmUpCount = 0
	private var settingsOpenCount = 0

	var counts: (requests: Int, warmUps: Int, settingsOpens: Int) {
		(requestCount, warmUpCount, settingsOpenCount)
	}

	func recordRequest() {
		requestCount += 1
	}

	func recordWarmUp() {
		warmUpCount += 1
	}

	func recordSettingsOpen() {
		settingsOpenCount += 1
	}
}
