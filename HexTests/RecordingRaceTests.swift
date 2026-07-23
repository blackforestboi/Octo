import AppKit
import AVFoundation
import ComposableArchitecture
import Darwin
import Foundation
import HexCore
import XCTest

@testable import Octo

@MainActor
final class RecordingRaceTests: XCTestCase {
  func testNewRecordingCancelsPendingDiscardCleanup() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let activeApp = NSWorkspace.shared.frontmostApplication
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("discard-cleanup-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    XCTAssertTrue(created)
    defer { try? FileManager.default.removeItem(at: stopURL) }

    let probe = RecordingProbe(stopURL: stopURL)
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {
        await probe.recordStart()
      }
      $0.recording.stopRecording = {
        await probe.beginStop()
      }
      $0.sleepManagement.preventSleep = { _ in }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }

    await probe.waitForPendingStop()

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = activeApp?.bundleIdentifier
      $0.sourceAppName = activeApp?.localizedName
    }

    await probe.resumePendingStop()
    await store.finish()

    let counts = await probe.counts()
    XCTAssertEqual(counts.startCalls, 2)
    XCTAssertEqual(counts.stopCalls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopURL.path))
  }

  func testStopGuardIgnoresOnlyStaleSessions() {
    let currentSessionID = UUID()

    XCTAssertFalse(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: currentSessionID
      )
    )
    XCTAssertFalse(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: nil,
        currentSessionID: currentSessionID
      )
    )
    XCTAssertTrue(
      RecordingClientLive.shouldIgnoreStopRequest(
        snapshotSessionID: currentSessionID,
        currentSessionID: UUID()
      )
    )
  }

  func testCaptureControllerIgnoresCallbacksFromOlderGeneration() {
    XCTAssertTrue(
      SuperFastCaptureController.shouldProcessCallback(
        callbackGeneration: 2,
        currentGeneration: 2
      )
    )
    XCTAssertFalse(
      SuperFastCaptureController.shouldProcessCallback(
        callbackGeneration: 1,
        currentGeneration: 2
      )
    )
  }

  func testCaptureStopBoundaryKeepsOnlyPCMFramesBeforeCutoff() {
    let sampleRate = 16_000.0
    let inputFrames = 1_600 // 100 ms
    let convertedFrames = 1_600
    let bufferStart = mach_absolute_time()
    let target = bufferStart + AVAudioTime.hostTime(forSeconds: 0.075)

    let inputFramesToWrite = SuperFastCaptureController.inputFramesToWrite(
      bufferStartHostTime: bufferStart,
      inputSampleRate: sampleRate,
      inputFrameCount: inputFrames,
      targetHostTime: target
    )
    let outputFramesToWrite = SuperFastCaptureController.outputFramesToWrite(
      convertedFrameCount: convertedFrames,
      inputFrameCount: inputFrames,
      inputFramesToWrite: inputFramesToWrite
    )

    XCTAssertTrue((1_199 ... 1_200).contains(inputFramesToWrite))
    XCTAssertTrue((1_199 ... 1_200).contains(outputFramesToWrite))
    XCTAssertTrue(
      SuperFastCaptureController.bufferReachesTarget(
        bufferStartHostTime: bufferStart,
        inputSampleRate: sampleRate,
        inputFrameCount: inputFrames,
        targetHostTime: target
      )
    )
  }

  func testCaptureStopBoundaryExcludesLaterPCMBuffer() {
    let sampleRate = 16_000.0
    let inputFrames = 1_600 // 100 ms
    let target = mach_absolute_time()
    let laterBufferStart = target + AVAudioTime.hostTime(forSeconds: 0.1)

    XCTAssertEqual(
      SuperFastCaptureController.inputFramesToWrite(
        bufferStartHostTime: laterBufferStart,
        inputSampleRate: sampleRate,
        inputFrameCount: inputFrames,
        targetHostTime: target
      ),
      0
    )
    XCTAssertTrue(
      SuperFastCaptureController.bufferReachesTarget(
        bufferStartHostTime: laterBufferStart,
        inputSampleRate: sampleRate,
        inputFrameCount: inputFrames,
        targetHostTime: target
      )
    )
  }

  func testFailedRecordingStopEndsTranscription() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let clock = TestClock()
    var state = Self.makeState()
    state.isRecording = true
    state.recordingStartTime = now
    state.$hexSettings.withLock { settings in
      settings.hotkey = HotKey(key: .a, modifiers: [.command])
    }
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.continuousClock = clock
      $0.recording.stopRecording = { .failed(.fallbackExportFailed("copy failed")) }
      $0.sleepManagement.allowSleep = {}
    }

    await store.send(.stopRecording) {
      $0.isRecording = false
      $0.isTranscribing = true
      $0.error = nil
      $0.isPrewarming = true
    }
    await store.receive(\.transcriptionError) {
      $0.isTranscribing = false
      $0.isPrewarming = false
      $0.error = "Failed to export recorded audio: copy failed"
    }
    await clock.advance(by: .seconds(5))
    await store.receive(\.dismissError) {
      $0.error = nil
    }
    await store.finish()
  }

  func testShortRecordingReleasesSleepAssertion() async throws {
    let now = Date(timeIntervalSince1970: 1_234)
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("short-recording-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: stopURL.path,
      contents: Data("test".utf8)
    )
    XCTAssertTrue(created)
    defer { try? FileManager.default.removeItem(at: stopURL) }

    let probe = SleepProbe()
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {}
      $0.recording.stopRecording = { .captured(stopURL) }
      $0.sleepManagement.preventSleep = { _ in
        await probe.recordPreventSleep()
      }
      $0.sleepManagement.allowSleep = {
        await probe.recordAllowSleep()
      }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      $0.sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    }
    await store.send(.stopRecording) {
      $0.isRecording = false
    }
    await store.finish()

    let counts = await probe.counts()
    XCTAssertEqual(counts.preventSleepCalls, 1)
    XCTAssertEqual(counts.allowSleepCalls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopURL.path))
  }

  func testDiscardCancelsPendingRecordingStart() async {
    let now = Date(timeIntervalSince1970: 1_234)
    let stopURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-start-discard-\(UUID().uuidString).wav")
    let sleepProbe = PendingSleepProbe()
    let recordingProbe = RecordingProbe(stopURL: stopURL)
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.date.now = now
      $0.recording.startRecording = {
        await recordingProbe.recordStart()
      }
      $0.recording.stopRecording = {
        await recordingProbe.beginImmediateStop()
      }
      $0.sleepManagement.preventSleep = { _ in
        await sleepProbe.preventSleep()
      }
      $0.sleepManagement.allowSleep = {}
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.startRecording) {
      $0.isRecording = true
      $0.recordingStartTime = now
      $0.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      $0.sourceAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    }
    await sleepProbe.waitUntilPending()
    await store.send(.discard) {
      $0.isRecording = false
      $0.isPrewarming = false
    }
    await sleepProbe.resume()
    await store.finish()

    let counts = await recordingProbe.counts()
    XCTAssertEqual(counts.startCalls, 0)
    XCTAssertEqual(counts.stopCalls, 1)
  }

  func testEmptyTranscriptionDeletesCapturedAudio() async throws {
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("empty-transcription-\(UUID().uuidString).wav")
    let created = FileManager.default.createFile(
      atPath: audioURL.path,
      contents: Data("test".utf8)
    )
    XCTAssertTrue(created)
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    }

    await store.send(.transcriptionAudioCaptured(audioURL, 1.25)) {
      $0.activeTranscriptionAudioURL = audioURL
      $0.activeTranscriptionDuration = 1.25
    }
    await store.send(.transcriptionResult("", audioURL)) {
      $0.activeTranscriptionAudioURL = nil
      $0.activeTranscriptionDuration = nil
    }
    await store.finish()

    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
  }

  func testHistoryUsesRecordingDurationCapturedAtStop() async {
    let duration = 1.25
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("history-duration-\(UUID().uuidString).wav")
    let transcript = Transcript(
      timestamp: Date(timeIntervalSince1970: 1_234),
      text: "hello",
      audioPath: audioURL,
      duration: duration,
      sourceAppBundleID: nil,
      sourceAppName: nil,
      status: .completed
    )
    let probe = TranscriptPersistenceProbe()
    let store = TestStore(initialState: Self.makeState()) {
      TranscriptionFeature()
    } withDependencies: {
      $0.transcriptPersistence.save = { request in
		await probe.record(duration: request.duration)
        return Transcript(
          id: transcript.id,
          timestamp: transcript.timestamp,
		  text: request.text,
		  audioPath: request.audioURL,
		  duration: request.duration,
		  sourceAppBundleID: request.sourceAppBundleID,
		  sourceAppName: request.sourceAppName,
		  status: request.status,
		  screenshotPath: request.screenshotData == nil ? nil : URL(fileURLWithPath: "/screenshot.png")
        )
      }
      $0.pasteboard.paste = { _ in }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.transcriptionAudioCaptured(audioURL, duration)) {
      $0.activeTranscriptionAudioURL = audioURL
      $0.activeTranscriptionDuration = duration
    }
    await store.send(.transcriptionResult("hello", audioURL)) {
      $0.activeTranscriptionAudioURL = nil
      $0.activeTranscriptionDuration = nil
      $0.isTranscribing = false
      $0.isPrewarming = false
    }
    while await probe.duration == nil {
      await Task.yield()
    }
    store.assert {
      $0.$transcriptionHistory.withLock { $0.history = [transcript] }
    }
    await store.finish()

    let storedDuration = await probe.duration
    XCTAssertEqual(storedDuration, duration)
  }

  func testTranscriptTextProcessorAppliesFormattingAfterWordTransforms() {
    var settings = HexSettings()
    settings.lowercaseTranscripts = true
    settings.removePunctuation = true

    XCTAssertEqual(
      TranscriptFormattingApplier.apply(
        "Hello, World!",
        lowercase: settings.lowercaseTranscripts,
        removePunctuation: settings.removePunctuation
      ),
      "hello world"
    )
  }

  func testScratchpadPreviewBypassesEveryTransform() async throws {
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("scratchpad-preview-\(UUID().uuidString).wav")
    XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
    defer { try? FileManager.default.removeItem(at: audioURL) }

    let pasteProbe = RefinementProbe()
    var state = Self.makeState()
    state.isTranscribing = true
    state.isRemappingScratchpadFocused = true
    state.$hexSettings.withLock {
      $0.lowercaseTranscripts = true
      $0.removePunctuation = true
      $0.saveTranscriptionHistory = false
    }
    let store = TestStore(initialState: state) {
      TranscriptionFeature()
    } withDependencies: {
      $0.pasteboard.paste = { text in await pasteProbe.recordPaste(text) }
      $0.soundEffects.play = { _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.transcriptionAudioCaptured(audioURL, 1))
    await store.send(.transcriptionResult("Hello, World!", audioURL))
    await store.finish()

    let pastedText = await pasteProbe.paste
    XCTAssertEqual(pastedText, "Hello, World!")
  }

	func testRefinementReceivesProcessedTranscriptAndKeepsAudioOwnedUntilItCompletes() async throws {
		let now = Date(timeIntervalSince1970: 1_234)
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("refinement-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let probe = RefinementProbe()
		var state = Self.makeState()
		state.isTranscribing = true
		state.isPrewarming = true
		state.forcedRefinementMode = .refined
		state.$hexSettings.withLock {
			$0.refinementMode = .refined
			$0.lowercaseTranscripts = true
			$0.removePunctuation = true
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
			$0.date.now = now
			$0.refinement.refine = { request in
				await probe.recordInput(request.text)
				return "refined text"
			}
			$0.pasteboard.paste = { text in await probe.recordPaste(text) }
			$0.soundEffects.play = { _ in }
			$0.transcriptPersistence.save = { _ in throw RefinementTestError.failed }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("Hello, World!", audioURL)) {
			$0.isTranscribing = false
			$0.isPrewarming = false
			$0.isRefining = true
		}
		await store.receive(\.refinementResult) {
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
			$0.isRefining = false
		}
		await store.finish()

		let refinementInput = await probe.input
		let pastedText = await probe.paste
		XCTAssertEqual(refinementInput, "hello world")
		XCTAssertEqual(pastedText, "refined text")
		XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
	}

	func testRefinementFailureReportsErrorWithoutPastingUnrefinedText() async throws {
		let now = Date(timeIntervalSince1970: 1_234)
		let clock = TestClock()
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("refinement-fallback-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let probe = RefinementProbe()
		var state = Self.makeState()
		state.isTranscribing = true
		state.forcedRefinementMode = .refined
		state.$hexSettings.withLock {
			$0.refinementMode = .refined
			$0.lowercaseTranscripts = true
			$0.removePunctuation = true
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
			$0.date.now = now
			$0.continuousClock = clock
			$0.refinement.refine = { _ in throw RefinementTestError.failed }
			$0.pasteboard.paste = { text in await probe.recordPaste(text) }
			$0.soundEffects.play = { _ in }
			$0.transcriptPersistence.save = { _ in throw RefinementTestError.failed }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("Hello, World!", audioURL)) {
			$0.isTranscribing = false
			$0.isRefining = true
		}
		await store.receive(\.transcriptionError)
		await clock.advance(by: .seconds(5))
		await store.receive(\.dismissError) {
			$0.error = nil
		}
		await store.finish()

		let pastedText = await probe.paste
		XCTAssertNil(pastedText)
		XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
	}

	func testCancellingRefinementOwnsAudioAndIgnoresLateResult() async throws {
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("refinement-cancel-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let refinementProbe = PendingRefinementProbe()
		let pasteProbe = RefinementProbe()
		var state = Self.makeState()
		state.isTranscribing = true
		state.forcedRefinementMode = .refined
		state.$hexSettings.withLock {
			$0.refinementMode = .refined
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) { TranscriptionFeature() } withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_234)
			$0.refinement.refine = { _ in try await refinementProbe.refine() }
			$0.pasteboard.paste = { text in await pasteProbe.recordPaste(text) }
			$0.sleepManagement.allowSleep = {}
			$0.soundEffects.play = { _ in }
			$0.transcriptPersistence.save = { _ in throw RefinementTestError.failed }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("keep this", audioURL)) {
			$0.isTranscribing = false
			$0.isRefining = true
		}
		await refinementProbe.waitUntilPending()

		await store.send(.cancel) {
			$0.isRefining = false
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
		}
		await refinementProbe.resume("late result")
		await store.finish()

		let pastedText = await pasteProbe.paste
		XCTAssertNil(pastedText)
		XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
	}

	func testRegularHotkeyStartsImmediatelyAndLateSelectionStillForcesRefinement() async throws {
		let now = Date(timeIntervalSince1970: 1_234)
		let audioURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("selected-text-race-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let captureProbe = PendingSelectedTextCaptureProbe()
		let refinementProbe = RefinementProbe()
		let rawPasteProbe = RefinementProbe()
		let selectedText = SelectedTextCapture(
			text: "draft message",
			replaceSelection: { text in
				await refinementProbe.recordPaste(text)
				return .replaced
			},
			cancelSelection: {}
		)
		var state = Self.makeState()
		state.$hexSettings.withLock {
			$0.hotkey = HotKey(key: .a, modifiers: [.command])
			$0.refinementInstructions = "Preserve Markdown."
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = now
			$0.pasteboard.captureSelectedText = { await captureProbe.capture() }
			$0.pasteboard.paste = { text in await rawPasteProbe.recordPaste(text) }
			$0.recording.startRecording = {}
			$0.recording.stopRecording = { .captured(audioURL) }
			$0.transcription.transcribe = { _, _, _, _ in "make it shorter" }
			$0.refinement.refine = { request in
				await refinementProbe.recordInput(request.text)
				await refinementProbe.recordInstructions(request.instructions)
				return "shorter draft"
			}
			$0.sleepManagement.preventSleep = { _ in }
			$0.sleepManagement.allowSleep = {}
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.hotKeyPressed)
		XCTAssertTrue(store.state.isRecording)
		await store.receive(\.refinedHotKeyPressed)
		await captureProbe.waitUntilPending()
		XCTAssertTrue(store.state.isRecording, "Selected-text lookup must not delay recording")
		XCTAssertTrue(store.state.isCapturingSelectedTextForRefinement)

		await store.send(.hotKeyReleased(.regular))
		await store.receive(\.transcriptionAudioCaptured)
		await store.receive(\.transcriptionResult)
		XCTAssertTrue(store.state.isTranscribing)
		XCTAssertEqual(store.state.pendingSelectedTextTranscription?.text, "make it shorter")
		let prematurePaste = await rawPasteProbe.paste
		XCTAssertNil(prematurePaste, "Raw text must wait for the parallel selection lookup")

		await captureProbe.resume(selectedText)
		await store.receive(\.selectedTextCaptured)
		await store.receive(\.transcriptionResult)
		await store.receive(\.refinementResult)
		await store.finish()

		let refinementInput = await refinementProbe.input
		let refinementInstructions = await refinementProbe.instructions
		let refinedPaste = await refinementProbe.paste
		let rawPaste = await rawPasteProbe.paste
		XCTAssertEqual(refinementInput, "draft message")
		XCTAssertEqual(
			refinementInstructions,
			"Preserve Markdown.\n\nSpoken instruction:\nmake it shorter"
		)
		XCTAssertEqual(refinedPaste, "shorter draft")
		XCTAssertNil(rawPaste)
	}

	func testDiscardCancelsParallelSelectionLookupWithoutStartingRefinementLater() async {
		let captureProbe = PendingSelectedTextCaptureProbe()
		let selectedText = SelectedTextCapture(
			text: "must not be refined",
			replaceSelection: { _ in .replaced },
			cancelSelection: {}
		)
		let store = TestStore(initialState: Self.makeState()) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_234)
			$0.pasteboard.captureSelectedText = { await captureProbe.capture() }
			$0.recording.startRecording = {}
			$0.recording.stopRecording = { .ignored(.noActiveRecording) }
			$0.sleepManagement.preventSleep = { _ in }
			$0.sleepManagement.allowSleep = {}
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.hotKeyPressed)
		await store.receive(\.refinedHotKeyPressed)
		await captureProbe.waitUntilPending()
		XCTAssertTrue(store.state.isCapturingSelectedTextForRefinement)

		await store.send(.discard)
		XCTAssertFalse(store.state.isCapturingSelectedTextForRefinement)
		await captureProbe.resume(selectedText)
		await store.finish()

		XCTAssertNil(store.state.selectedTextForRefinement)
		XCTAssertFalse(store.state.isRefining)
	}

	func testSelectedTextRefinementUsesSpokenInstruction() async throws {
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("selected-text-refinement-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let refinementProbe = RefinementProbe()
		let selectedText = SelectedTextCapture(
			text: "draft message",
			replaceSelection: { text in
				await refinementProbe.recordPaste(text)
				return .replaced
			},
			cancelSelection: {}
		)
		var state = Self.makeState()
		state.isTranscribing = true
		state.forcedRefinementMode = .refined
		state.selectedTextForRefinement = selectedText
		state.$hexSettings.withLock {
			$0.refinementInstructions = "Preserve Markdown."
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_234)
			$0.refinement.refine = { request in
				await refinementProbe.recordInput(request.text)
				await refinementProbe.recordInstructions(request.instructions)
				return "shorter draft"
			}
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("make it shorter", audioURL)) {
			$0.isTranscribing = false
			$0.isRefining = true
		}
		await store.receive(\.refinementResult) {
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
			$0.isRefining = false
			$0.selectedTextForRefinement = nil
			$0.forcedRefinementMode = nil
			$0.activeRecordingHotkey = nil
			$0.activeMinimumKeyTime = nil
			$0.activeRecordingSource = nil
		}
		await store.finish()

		let refinementInput = await refinementProbe.input
		let refinementInstructions = await refinementProbe.instructions
		let refinedPaste = await refinementProbe.paste
		XCTAssertEqual(refinementInput, "draft message")
		XCTAssertEqual(refinementInstructions, "Preserve Markdown.\n\nSpoken instruction:\nmake it shorter")
		XCTAssertEqual(refinedPaste, "shorter draft")
	}

	func testSilentSelectedTextRefinementUsesDefaultInstructions() async throws {
		let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("silent-selected-text-refinement-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let refinementProbe = RefinementProbe()
		let selectedText = SelectedTextCapture(
			text: "draft message",
			replaceSelection: { text in
				await refinementProbe.recordPaste(text)
				return .replaced
			},
			cancelSelection: {}
		)
		var state = Self.makeState()
		state.isTranscribing = true
		state.forcedRefinementMode = .refined
		state.selectedTextForRefinement = selectedText
		state.$hexSettings.withLock {
			$0.refinementInstructions = "Preserve Markdown."
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_234)
			$0.refinement.refine = { request in
				await refinementProbe.recordInput(request.text)
				await refinementProbe.recordInstructions(request.instructions)
				return "refined draft"
			}
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.transcriptionAudioCaptured(audioURL, 2)) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 2
		}
		await store.send(.transcriptionResult("", audioURL)) {
			$0.isTranscribing = false
			$0.isRefining = true
		}
		await store.receive(\.refinementResult) {
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
			$0.isRefining = false
			$0.selectedTextForRefinement = nil
			$0.forcedRefinementMode = nil
			$0.activeRecordingHotkey = nil
			$0.activeMinimumKeyTime = nil
			$0.activeRecordingSource = nil
		}
		await store.finish()

		let refinementInput = await refinementProbe.input
		let refinementInstructions = await refinementProbe.instructions
		let refinedPaste = await refinementProbe.paste
		XCTAssertEqual(refinementInput, "draft message")
		XCTAssertEqual(refinementInstructions, "Preserve Markdown.")
		XCTAssertEqual(refinedPaste, "refined draft")
	}

	func testTerminalTapCancelsPendingSelectionCapture() async {
		let captureProbe = PendingSelectedTextCaptureProbe()
		var state = Self.makeState()
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.pasteboard.captureSelectedText = { await captureProbe.capture() }
		}

		await store.send(.refinedHotKeyPressed) {
			$0.isCapturingSelectedTextForRefinement = true
		}
		await captureProbe.waitUntilPending()
		await store.send(.hotKeyReleased(.refined)) {
			$0.refinedHotKeyReleasedWhileCapturingSelection = true
		}
		await captureProbe.resume(nil)
		await store.receive(\.selectedTextCaptureUnavailable) {
			$0.isCapturingSelectedTextForRefinement = false
			$0.refinedHotKeyReleasedWhileCapturingSelection = false
		}
		await store.finish()
	}

	func testScreenAwareIndicatorActivatesForRegularRecording() async {
		var state = Self.makeState()
		state.isRecording = true
		state.activeRecordingSource = .regular
		let context = Self.makeScreenContext()
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.uuid = .constant(UUID(1))
			$0.screenCapture.captureDisplayUnderCursor = { _ in context }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.screenAwareModeActivated) {
			$0.isScreenAwareModeActive = true
			$0.forcedRefinementMode = .refined
		}
		await store.receive(\.screenContextCaptured)
		await store.finish()
	}

	func testScreenAwareIndicatorDoesNotActivateOutsideActiveRecording() async {
		let store = TestStore(initialState: Self.makeState()) {
			TranscriptionFeature()
		}

		await store.send(.screenAwareModeActivated)
		await store.finish()
	}

	func testScreenAwareCountdownEligibilityAllowsLocalOCRWithoutOpenRouter() {
		var settings = HexSettings(screenAwareDictationEnabled: true)

		XCTAssertTrue(ScreenAwareActivation.shouldStartCountdown(
			isPressAndHold: true,
			settings: settings,
			hasOpenRouterKey: false
		))
		XCTAssertFalse(ScreenAwareActivation.shouldStartCountdown(
			isPressAndHold: false,
			settings: settings,
			hasOpenRouterKey: false
		))

		settings.screenAwareInputSource = .image
		settings.screenAwareOpenRouterModelID = "vision-model"

		XCTAssertTrue(ScreenAwareActivation.shouldStartCountdown(
			isPressAndHold: true,
			settings: settings,
			hasOpenRouterKey: true
		))
		XCTAssertFalse(ScreenAwareActivation.shouldStartCountdown(
			isPressAndHold: true,
			settings: settings,
			hasOpenRouterKey: false
		))

		settings.screenAwareOpenRouterModelID = nil
		XCTAssertFalse(ScreenAwareActivation.shouldStartCountdown(
			isPressAndHold: true,
			settings: settings,
			hasOpenRouterKey: true
		))
	}

	func testDoubleTapOnlyFirstHoldStartsOnDemandRecordingAfterThreshold() async {
		let activationID = UUID(0)
		let clock = TestClock()
		var state = Self.makeState()
		state.$hexSettings.withLock {
			$0.hotkey = HotKey(key: .a, modifiers: [.command])
			$0.includeSelectedTextInRefinement = false
		}
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_234)
			$0.continuousClock = clock
			$0.uuid = .constant(activationID)
			$0.recording.startRecording = {}
			$0.recording.stopRecording = { .ignored(.noActiveRecording) }
			$0.sleepManagement.preventSleep = { _ in }
			$0.sleepManagement.allowSleep = {}
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.armPendingPressAndHold)
		XCTAssertEqual(store.state.pendingPressAndHoldActivationID, activationID)
		await clock.advance(by: .seconds(0.29))
		XCTAssertFalse(store.state.isRecording)

		await clock.advance(by: .seconds(0.01))
		await store.receive(\.pendingPressAndHoldActivated)
		await store.receive(\.hotKeyPressed)
		await store.receive(\.startRecording)
		XCTAssertTrue(store.state.isRecording)
		XCTAssertEqual(store.state.activeRecordingSource, .regular)

		await store.send(.discard)
		await store.finish()
	}

	func testDoubleTapOnlyQuickFirstTapCancelsPendingOnDemandRecording() async {
		let activationID = UUID(0)
		let clock = TestClock()
		let store = TestStore(initialState: Self.makeState()) {
			TranscriptionFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.uuid = .constant(activationID)
		}

		await store.send(.armPendingPressAndHold) {
			$0.pendingPressAndHoldActivationID = activationID
		}
		await store.send(.cancelPendingPressAndHold) {
			$0.pendingPressAndHoldActivationID = nil
		}
		await clock.advance(by: .seconds(1))
		XCTAssertFalse(store.state.isRecording)
		await store.finish()
	}

	func testScreenAwareActivationSkipsSelectedTextCapture() async {
		let context = Self.makeScreenContext()
		var state = Self.makeState()
		state.isRecording = true
		state.activeRecordingSource = .regular
		state.$hexSettings.withLock { $0.includeSelectedTextInRefinement = true }
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_234)
			$0.uuid = .constant(UUID(1))
			$0.recording.startRecording = {}
			$0.sleepManagement.preventSleep = { _ in }
			$0.soundEffects.play = { _ in }
			$0.screenCapture.captureDisplayUnderCursor = { _ in context }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.screenAwareModeActivated)
		XCTAssertTrue(store.state.isRecording)
		XCTAssertEqual(store.state.activeRecordingSource, .regular)
		XCTAssertTrue(store.state.isScreenAwareModeActive)
		XCTAssertEqual(store.state.forcedRefinementMode, .refined)
		XCTAssertFalse(store.state.isCapturingSelectedTextForRefinement)
		await store.receive(\.screenContextCaptured)
		await store.finish()
	}

	func testRegularHotkeyWithoutSelectionStopsNormallyAndPastesBaseline() async throws {
		let now = Date(timeIntervalSince1970: 1_234)
		let audioURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("no-selection-hotkey-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }
		let pasteProbe = RefinementProbe()
		var state = Self.makeState()
		state.$hexSettings.withLock {
			$0.hotkey = HotKey(key: .a, modifiers: [.command])
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = now
			$0.pasteboard.captureSelectedText = { nil }
			$0.pasteboard.paste = { text in await pasteProbe.recordPaste(text) }
			$0.recording.startRecording = {}
			$0.recording.stopRecording = { .captured(audioURL) }
			$0.transcription.transcribe = { _, _, _, _ in "ordinary transcript" }
			$0.refinement.refine = { _ in throw RefinementTestError.failed }
			$0.sleepManagement.preventSleep = { _ in }
			$0.sleepManagement.allowSleep = {}
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.hotKeyPressed)
		await store.receive(\.refinedHotKeyPressed)
		await store.receive(\.selectedTextCaptureUnavailable)
		XCTAssertTrue(store.state.isRecording)
		XCTAssertNil(store.state.forcedRefinementMode)

		await store.send(.hotKeyReleased(.regular))
		await store.receive(\.transcriptionAudioCaptured)
		await store.receive(\.transcriptionResult)
		await store.finish()

		let pastedText = await pasteProbe.paste
		XCTAssertEqual(pastedText, "ordinary transcript")
	}

	func testTerminalHoldFinishesRegularRecordingWithRefinement() async throws {
		let now = Date(timeIntervalSince1970: 1_234)
		let activationID = UUID(0)
		let clock = TestClock()
		let audioURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("refined-finish-\(UUID().uuidString).wav")
		XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
		defer { try? FileManager.default.removeItem(at: audioURL) }

		let refinementProbe = RefinementProbe()
		let regularHotkey = HotKey(key: .a, modifiers: [.command])
		var state = Self.makeState()
		state.isRecording = true
		state.recordingStartTime = now.addingTimeInterval(-1)
		state.activeRecordingHotkey = regularHotkey
		state.activeMinimumKeyTime = 0.2
		state.activeRecordingSource = .regular
		state.$hexSettings.withLock {
			$0.hotkey = regularHotkey
			$0.refinementMode = .raw
			$0.saveTranscriptionHistory = false
		}
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = now
			$0.continuousClock = clock
			$0.uuid = .constant(activationID)
			$0.recording.stopRecording = { .captured(audioURL) }
			$0.transcription.transcribe = { _, _, _, _ in "dictated text" }
			$0.refinement.refine = { request in
				await refinementProbe.recordInput(request.text)
				return "refined text"
			}
			$0.pasteboard.paste = { _ in }
			$0.sleepManagement.allowSleep = {}
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.armTerminalRefinement) {
			$0.pendingTerminalRefinementID = activationID
		}
		await clock.advance(by: .seconds(0.74))
		XCTAssertTrue(store.state.isRecording)
		XCTAssertNil(store.state.forcedRefinementMode)

		await clock.advance(by: .seconds(0.01))
		await store.receive(\.terminalRefinementActivated) {
			$0.pendingTerminalRefinementID = nil
		}
		await store.receive(\.finishRecordingWithRefinement) {
			$0.forcedRefinementMode = .refined
		}
		await store.receive(\.stopRecording) {
			$0.isRecording = false
			$0.isTranscribing = true
			$0.error = nil
			$0.isPrewarming = true
		}
		await store.receive(\.transcriptionAudioCaptured) {
			$0.activeTranscriptionAudioURL = audioURL
			$0.activeTranscriptionDuration = 1
		}
		await store.receive(\.transcriptionResult) {
			$0.isTranscribing = false
			$0.isPrewarming = false
			$0.isRefining = true
		}
		await store.receive(\.refinementResult) {
			$0.activeTranscriptionAudioURL = nil
			$0.activeTranscriptionDuration = nil
			$0.isRefining = false
			$0.forcedRefinementMode = nil
			$0.activeRecordingHotkey = nil
			$0.activeMinimumKeyTime = nil
			$0.activeRecordingSource = nil
		}
		await store.finish()

		let refinementInput = await refinementProbe.input
		XCTAssertEqual(refinementInput, "dictated text")
		XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
	}

	func testQuickTerminalReleaseCancelsAutomaticRefinement() async {
		let activationID = UUID(0)
		let clock = TestClock()
		var state = Self.makeState()
		state.isRecording = true
		state.recordingStartTime = Date(timeIntervalSince1970: 1_233)
		state.activeRecordingHotkey = HotKey(key: .a, modifiers: [.command])
		state.activeMinimumKeyTime = 0.2
		state.activeRecordingSource = .regular
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_234)
			$0.continuousClock = clock
			$0.uuid = .constant(activationID)
			$0.recording.stopRecording = { .ignored(.noActiveRecording) }
			$0.sleepManagement.allowSleep = {}
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.armTerminalRefinement)
		XCTAssertEqual(store.state.pendingTerminalRefinementID, activationID)
		await clock.advance(by: .seconds(0.25))

		await store.send(.hotKeyReleased(.regular))
		XCTAssertNil(store.state.pendingTerminalRefinementID)
		await store.receive(\.stopRecording)
		XCTAssertFalse(store.state.isRecording)
		XCTAssertNil(store.state.forcedRefinementMode)

		await clock.advance(by: .seconds(1))
		XCTAssertNil(store.state.forcedRefinementMode)
		await store.finish()
	}

	func testQuickFollowUpTapRefinesTranscriptThatWasAlreadyPasted() async {
		let transcriptID = UUID()
		let refinementProbe = RefinementProbe()
		var state = Self.makeState()
		state.recentCompletedTranscript = .init(
			id: transcriptID,
			text: "already pasted transcript",
			historyID: nil
		)
		state.$hexSettings.withLock {
			$0.refinementInstructions = "Make it concise."
		}
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = Date(timeIntervalSince1970: 1_234)
			$0.refinement.refine = { request in
				await refinementProbe.recordInput(request.text)
				return "concise transcript"
			}
			$0.pasteboard.paste = { text in await refinementProbe.recordPaste(text) }
			$0.soundEffects.play = { _ in }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.refineMostRecentTranscription)
		XCTAssertTrue(store.state.isRefining)
		await store.receive(\.recentTranscriptRefined)
		await store.finish()

		let refinementInput = await refinementProbe.input
		let refinedPaste = await refinementProbe.paste
		XCTAssertEqual(refinementInput, "already pasted transcript")
		XCTAssertEqual(refinedPaste, "concise transcript")
		XCTAssertEqual(store.state.recentCompletedTranscript?.text, "concise transcript")
	}

	func testScreenAwareActivationCapturesBeforeFinish() async {
		let now = Date(timeIntervalSince1970: 1_234)
		let context = Self.makeScreenContext()
		let captureProbe = PendingScreenCaptureProbe()
		var state = Self.makeState()
		state.isRecording = true
		state.recordingStartTime = now
		state.activeRecordingSource = .regular
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = now
			$0.uuid = .constant(UUID(1))
			$0.screenCapture.captureDisplayUnderCursor = { _ in
				return try await captureProbe.capture()
			}
			$0.recording.stopRecording = { .ignored(.noActiveRecording) }
			$0.sleepManagement.allowSleep = {}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.screenAwareModeActivated)
		await captureProbe.waitUntilPending()
		XCTAssertTrue(store.state.isRecording)
		XCTAssertTrue(store.state.isScreenAwareModeActive)
		XCTAssertEqual(store.state.forcedRefinementMode, .refined)

		await captureProbe.resume(returning: context)
		await store.receive(\.screenContextCaptured)
		XCTAssertTrue(store.state.isRecording)
		XCTAssertTrue(store.state.isScreenAwareModeActive)
		XCTAssertEqual(store.state.screenContextForRefinement, context)

		await store.send(.finishScreenAwareRecording)
		XCTAssertFalse(store.state.isScreenAwareModeActive)
		await store.receive(\.stopRecording)
		await store.finish()
	}

	func testRegularHotKeyReleaseFinishesScreenAwareMode() async {
		var state = Self.makeState()
		state.isRecording = true
		state.activeRecordingSource = .regular
		state.isScreenAwareModeActive = true
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.recording.stopRecording = { .ignored(.noActiveRecording) }
			$0.sleepManagement.allowSleep = {}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.hotKeyReleased(.regular))
		await store.receive(\.finishScreenAwareRecording) {
			$0.isScreenAwareModeActive = false
		}
		await store.receive(\.stopRecording)
		await store.finish()
	}

	func testScreenAwareSecondTapActivatesAtThresholdBeforeRelease() async {
		let clock = TestClock()
		let now = Date(timeIntervalSince1970: 1_234)
		let context = Self.makeScreenContext()
		var state = Self.makeState()
		state.isRecording = true
		state.recordingStartTime = now
		state.activeRecordingSource = .regular
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.date.now = now
			$0.uuid = .constant(UUID(1))
			$0.screenCapture.captureDisplayUnderCursor = { _ in context }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.armScreenAwareActivation)
		await clock.advance(by: .seconds(0.74))
		XCTAssertFalse(store.state.isScreenAwareModeActive)
		await clock.advance(by: .seconds(0.01))
		await store.receive(\.screenAwareActivationThresholdReached)
		await store.receive(\.screenAwareModeActivated)
		await store.receive(\.screenContextCaptured)
		XCTAssertTrue(store.state.isScreenAwareModeActive)
		XCTAssertEqual(store.state.forcedRefinementMode, .refined)
		// No hotKeyReleased action is sent: activation must happen while held.
		await store.send(.cancelScreenAwareActivation)
		await store.finish()
	}

	func testScreenCaptureFailureDoesNotStopScreenAwareRecording() async {
		let now = Date(timeIntervalSince1970: 1_234)
		var state = Self.makeState()
		state.isRecording = true
		state.recordingStartTime = now
		state.activeRecordingSource = .regular
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.date.now = now
			$0.uuid = .constant(UUID(1))
			$0.screenCapture.captureDisplayUnderCursor = { _ in throw ScreenCaptureFlowTestError.failed }
			$0.recording.stopRecording = { .ignored(.noActiveRecording) }
			$0.sleepManagement.allowSleep = {}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.screenAwareModeActivated)
		await store.receive(\.screenContextCaptureFailed)
		XCTAssertFalse(store.state.isScreenAwareModeActive)
		XCTAssertTrue(store.state.isRecording)
		XCTAssertEqual(store.state.forcedRefinementMode, .refined)
		await store.finish()
	}

	func testTranscriptionErrorClearsScreenAwareIndicatorDuringCapture() async {
		let clock = TestClock()
		var state = Self.makeState()
		state.isTranscribing = true
		state.isScreenAwareModeActive = true
		state.screenContextCaptureID = UUID()
		let store = TestStore(initialState: state) {
			TranscriptionFeature()
		} withDependencies: {
			$0.continuousClock = clock
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.transcriptionError(ScreenCaptureFlowTestError.failed, nil))
		XCTAssertFalse(store.state.isScreenAwareModeActive)
		XCTAssertNil(store.state.screenContextCaptureID)
		await clock.advance(by: .seconds(5))
		await store.receive(\.dismissError)
		await store.finish()
	}

	  private static func makeState() -> TranscriptionFeature.State {
    TranscriptionFeature.State(
      hexSettings: Shared(value: .init()),
      isRemappingScratchpadFocused: false,
      modelBootstrapState: Shared(value: .init(isModelReady: true)),
      transcriptionHistory: Shared(value: .init())
    )
	  }

	private static func makeScreenContext() -> ScreenContext {
		ScreenContext(
			imagePNGData: Data([0x89, 0x50, 0x4E, 0x47]),
			recognizedText: "Visible account balance",
			pixelWidth: 1920,
			pixelHeight: 1080,
			cursorX: 640,
			cursorY: 480
		)
	}
	}

private actor RefinementProbe {
	private(set) var input: String?
	private(set) var instructions: String?
	private(set) var paste: String?

	func recordInput(_ value: String) { input = value }
	func recordInstructions(_ value: String) { instructions = value }
	func recordPaste(_ value: String) { paste = value }
}

private actor PendingSelectedTextCaptureProbe {
	private var continuation: CheckedContinuation<SelectedTextCapture?, Never>?

	func capture() async -> SelectedTextCapture? {
		await withCheckedContinuation { continuation in
			self.continuation = continuation
		}
	}

	func waitUntilPending() async {
		while continuation == nil {
			await Task.yield()
		}
	}

	func resume(_ selectedText: SelectedTextCapture?) {
		continuation?.resume(returning: selectedText)
		continuation = nil
	}
}

private enum RefinementTestError: Error {
	case failed
}

private enum ScreenCaptureFlowTestError: Error {
	case failed
}

private actor PendingScreenCaptureProbe {
	private var continuation: CheckedContinuation<ScreenContext, Error>?

	func capture() async throws -> ScreenContext {
		try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
		}
	}

	func waitUntilPending() async {
		while continuation == nil {
			await Task.yield()
		}
	}

	func resume(returning context: ScreenContext) {
		continuation?.resume(returning: context)
		continuation = nil
	}
}

private actor PendingRefinementProbe {
	private var continuation: CheckedContinuation<String, Error>?

	func refine() async throws -> String {
		try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
		}
	}

	func waitUntilPending() async {
		while continuation == nil {
			await Task.yield()
		}
	}

	func resume(_ text: String) {
		continuation?.resume(returning: text)
		continuation = nil
	}
}

private actor RecordingProbe {
  private let stopURL: URL
  private var startCalls = 0
  private var stopCalls = 0
  private var stopContinuation: CheckedContinuation<RecordingStopResult, Never>?

  init(stopURL: URL) {
    self.stopURL = stopURL
  }

  func recordStart() {
    startCalls += 1
  }

  func beginStop() async -> RecordingStopResult {
    stopCalls += 1
    return await withCheckedContinuation { continuation in
      stopContinuation = continuation
    }
  }

  func beginImmediateStop() -> RecordingStopResult {
    stopCalls += 1
    return .captured(stopURL)
  }

  func waitForPendingStop() async {
    while stopContinuation == nil {
      await Task.yield()
    }
  }

  func resumePendingStop() {
    stopContinuation?.resume(returning: .captured(stopURL))
    stopContinuation = nil
  }

  func counts() -> (startCalls: Int, stopCalls: Int) {
    (startCalls, stopCalls)
  }
}

private actor SleepProbe {
  private var preventSleepCalls = 0
  private var allowSleepCalls = 0

  func recordPreventSleep() {
    preventSleepCalls += 1
  }

  func recordAllowSleep() {
    allowSleepCalls += 1
  }

  func counts() -> (preventSleepCalls: Int, allowSleepCalls: Int) {
    (preventSleepCalls, allowSleepCalls)
  }
}

private actor PendingSleepProbe {
  private var continuation: CheckedContinuation<Void, Never>?

  func preventSleep() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilPending() async {
    while continuation == nil {
      await Task.yield()
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private actor TranscriptPersistenceProbe {
  private(set) var duration: TimeInterval?

  func record(duration: TimeInterval) {
    self.duration = duration
  }
}
