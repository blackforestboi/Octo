import ComposableArchitecture
import Foundation
import HexCore
import XCTest

@testable import Octo

@MainActor
final class LiveTranscriptionFeatureTests: XCTestCase {
	func testLiveToggleChangesOnlyWhileFullyPaused() async {
		let sessionID = UUID()
		var state = TranscriptionFeature.State()
		state.recordingSession = .init(
			id: sessionID,
			title: "Session",
			phase: .paused,
			speakerIdentificationEnabled: false,
			systemAudioEnabled: false,
			liveTranscriptionEnabled: true,
			speakerMode: .highAccuracyFour
		)
		let store = TestStore(initialState: state) { TranscriptionFeature() }

		await store.send(.recordingSessionLiveTranscriptionChanged(false)) {
			$0.recordingSession?.liveTranscriptionEnabled = false
		}
		await store.finish()

		var drainingState = store.state
		drainingState.recordingSession?.phase = .drainingForPause
		let drainingStore = TestStore(initialState: drainingState) { TranscriptionFeature() }
		await drainingStore.send(.recordingSessionLiveTranscriptionChanged(true))
		XCTAssertFalse(drainingStore.state.recordingSession?.liveTranscriptionEnabled ?? true)
	}

	func testSpeakerModeLocksAfterFirstDurableCommit() async {
		var state = TranscriptionFeature.State()
		state.recordingSession = .init(
			id: UUID(),
			title: "Session",
			phase: .paused,
			speakerIdentificationEnabled: true,
			systemAudioEnabled: false,
			liveTranscriptionEnabled: true,
			speakerMode: .highAccuracyFour,
			hasCommittedLiveTranscript: true
		)
		let store = TestStore(initialState: state) { TranscriptionFeature() }

		await store.send(.recordingSessionSpeakerModeChanged(.moreSpeakersTen))

		XCTAssertEqual(store.state.recordingSession?.speakerMode, .highAccuracyFour)
	}

	func testRecordingSessionCreatesHistoryWhenOrdinaryHistoryIsDisabled() async {
		let generation = UUID()
		var state = TranscriptionFeature.State()
		state.isRecording = true
		state.$hexSettings.withLock {
			$0.saveTranscriptionHistory = false
			$0.maxHistoryEntries = nil
		}
		state.$transcriptionHistory.withLock { $0.history = [] }
		state.recordingSession = .init(
			id: UUID(),
			title: "Session",
			phase: .recording,
			speakerIdentificationEnabled: false,
			systemAudioEnabled: false,
			liveTranscriptionEnabled: false,
			speakerMode: .highAccuracyFour
		)
		let store = TestStore(initialState: state) { TranscriptionFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.recordingCheckpointStarted(.init(
			sessionID: generation,
			createdAt: Date(timeIntervalSince1970: 1),
			audioURL: URL(fileURLWithPath: "/tmp/session.wav")
		)))
		await store.finish()

		XCTAssertEqual(store.state.transcriptionHistory.history.count, 1)
		XCTAssertNotNil(store.state.transcriptionHistory.history.first?.recordingSessionID)
	}

	func testDrainCompletesTakeBeforeReturningToPaused() async {
		let generation = UUID()
		let historyID = UUID()
		var state = TranscriptionFeature.State()
		state.recordingSession = .init(
			id: UUID(),
			title: "Session",
			phase: .drainingForPause,
			speakerIdentificationEnabled: false,
			systemAudioEnabled: false,
			liveTranscriptionEnabled: true,
			speakerMode: .highAccuracyFour
		)
		state.liveTakeGeneration = generation
		state.activeHistoryTranscriptID = historyID
		state.isTranscribing = true
		state.$transcriptionHistory.withLock {
			$0.history = [.init(
				id: historyID,
				timestamp: .now,
				text: "Committed.",
				audioPath: URL(fileURLWithPath: "/tmp/session.wav"),
				duration: 1,
				status: .processing,
				liveTranscriptCheckpoint: .init(takeGeneration: generation, drainState: .drainingForPause)
			)]
		}
		let store = TestStore(initialState: state) { TranscriptionFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.liveTranscriptionEvent(.drained(generation)))

		XCTAssertEqual(store.state.recordingSession?.phase, .paused)
		XCTAssertFalse(store.state.isTranscribing)
		XCTAssertEqual(store.state.transcriptionHistory.history.first?.status, .completed)
		XCTAssertEqual(store.state.transcriptionHistory.history.first?.liveTranscriptCheckpoint?.drainState, .drained)
	}

	func testCommitDoesNotBecomeVisibleWhenDurableSaveFails() async {
		let generation = UUID()
		let historyID = UUID()
		let checkpoint = LiveTranscriptCheckpoint(
			sources: [.microphone: .init()],
			takeGeneration: generation
		)
		var state = TranscriptionFeature.State()
		state.liveTakeGeneration = generation
		state.activeHistoryTranscriptID = historyID
		state.liveTranscriptCoordinator = .init(
			mode: .highAccuracyFour,
			takeGeneration: generation,
			targetDelay: 0,
			checkpoint: checkpoint
		)
		state.$transcriptionHistory.withLock {
			$0.history = [.init(
				id: historyID,
				timestamp: .now,
				text: "",
				audioPath: URL(fileURLWithPath: "/tmp/session.wav"),
				duration: 0,
				status: .processing,
				liveTranscriptCheckpoint: checkpoint
			)]
		}
		let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
			$0.liveHistoryPersistence = .init(persist: { _ in
				throw NSError(domain: "LiveHistoryPersistenceTests", code: 1)
			})
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let words = [TimedTranscriptWord(word: "Durable.", startTime: 0, endTime: 1)]

		await store.send(.liveTranscriptionEvent(.hypothesis(.init(
			source: .microphone,
			takeGeneration: generation,
			generation: 1,
			words: words,
			isProviderConfirmed: true,
			containsSpeech: true,
			processedThrough: 1
		))))
		await store.send(.liveTranscriptionEvent(.hypothesis(.init(
			source: .microphone,
			takeGeneration: generation,
			generation: 2,
			words: words,
			isProviderConfirmed: true,
			containsSpeech: true,
			processedThrough: 1
		))))

		XCTAssertTrue(store.state.transcriptionHistory.history[0].text.isEmpty)
		XCTAssertTrue(store.state.transcriptionHistory.history[0].timestampedSections?.isEmpty ?? true)
		XCTAssertTrue(store.state.liveSourcesNeedingFileRecovery.contains(.microphone))
	}
}
