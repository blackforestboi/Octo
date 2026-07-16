//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

enum ScreenAwareActivation {
	static let minimumHoldDuration: TimeInterval = 0.75

	static func holdDuration(for settings: HexSettings) -> TimeInterval {
		max(settings.refinedMinimumKeyTime, minimumHoldDuration)
	}

	static func isAvailable(with settings: HexSettings) -> Bool {
		isAvailable(
			settings: settings,
			hasOpenRouterKey: !(OpenRouterAPIKeyStore.read() ?? "").isEmpty
		)
	}

	static func shouldStartCountdown(
		isPressAndHold: Bool,
		settings: HexSettings,
		hasOpenRouterKey: Bool
	) -> Bool {
		isPressAndHold && isAvailable(settings: settings, hasOpenRouterKey: hasOpenRouterKey)
	}

	private static func isAvailable(settings: HexSettings, hasOpenRouterKey: Bool) -> Bool {
		guard settings.isScreenAwareDictationConfigured else { return false }
		// Local OCR is refined by the selected provider; it does not need a vision
		// model, but remote providers still need their own credential.
		guard settings.screenAwareInputSource.uploadsScreenshot else {
			switch settings.refinementProvider {
			case .apple:
				return true
			case .gemini:
				return !(GeminiAPIKeyStore.read() ?? "").isEmpty
			case .openRouter:
				return hasOpenRouterKey
			case .openAI:
				return !(OpenAIAPIKeyStore.read() ?? "").isEmpty
			case .anthropic:
				return !(AnthropicAPIKeyStore.read() ?? "").isEmpty
			}
		}
		guard settings.hasScreenAwareImageFallbackModel else { return false }
		switch settings.refinementProvider {
		case .openAI:
			return !(OpenAIAPIKeyStore.read() ?? "").isEmpty
		case .anthropic:
			return !(AnthropicAPIKeyStore.read() ?? "").isEmpty
		case .openRouter:
			return hasOpenRouterKey
		case .apple, .gemini:
			return hasOpenRouterKey
		}
	}
}

@Reducer
struct TranscriptionFeature {
  enum RecordingSource: Equatable {
    case regular
    case refined
  }

	struct PendingScreenAwareTranscription: Equatable {
		let text: String
		let audioURL: URL
		let duration: TimeInterval
	}

  @ObservableState
  struct State: Equatable {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
	var isRefining: Bool = false
		var isScreenAwareModeActive = false
		var isCapturingSelectedTextForRefinement = false
		var refinedHotKeyReleasedWhileCapturingSelection = false
			var selectedTextForRefinement: SelectedTextCapture?
			var originalTranscriptForRefinement: String?
			var screenContextForRefinement: ScreenContext?
			/// Snapshot the selected source so changing Settings mid-run cannot alter the request.
			var screenAwareInputSourceForRefinement: ScreenAwareInputSource?
			/// The screen image is staged to permanent storage immediately after capture,
			/// before an audio checkpoint necessarily exists.
			var stagedScreenContextScreenshotPath: URL?
			/// The durable History row created as soon as the recorder produces audio.
			var activeHistoryTranscriptID: UUID?
			var screenAwareActivationID: UUID?
			var cancelledScreenAwareActivationID: UUID?
			var screenContextCaptureID: UUID?
			var screenContextCaptureErrorMessage: String?
				var pendingScreenAwareTranscription: PendingScreenAwareTranscription?
    var isPrewarming: Bool = false
		var forcedRefinementMode: RefinementMode?
		var activeRecordingHotkey: HotKey?
		var activeMinimumKeyTime: Double?
		var activeRecordingSource: RecordingSource?
	var error: String?
	var recordingStartTime: Date?
	var outputGenerationStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    /// URL of the audio file currently being transcribed. Set after `recording.stopRecording()`
    /// returns inside `handleStopRecording`'s effect, cleared on every terminal action so a
    /// late-arriving result/error from a cancelled transcription can be detected and dropped.
    var activeTranscriptionAudioURL: URL?
    /// Recording duration captured at stop time (does NOT include transcription latency).
    /// Paired with `activeTranscriptionAudioURL`; both set and cleared together.
    var activeTranscriptionDuration: TimeInterval?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased(RecordingSource)
			case refinedHotKeyPressed
			case startScreenAwareActivationCountdown(UUID)
			case refinedLockEstablished(UUID, Bool)
			case screenAwareModeActivated(UUID)
				case finishRecordingWithRefinement
				case finishScreenAwareRecording
				case selectedTextCaptured(SelectedTextCapture)
				case selectedTextCaptureUnavailable
				case screenContextCaptured(UUID, ScreenContext)
				case screenContextArtifactPersisted(UUID, URL)
				case screenContextCaptureFailed(UUID, Error)

    // Recording flow
    case startRecording
		case startRefinedRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)
		case hotKeyCancelled(RecordingSource)
		case hotKeyDiscarded(RecordingSource)

    // Transcription result flow
    case transcriptionAudioCaptured(URL, TimeInterval)
		case transcriptionCheckpointPersisted(Transcript)
    case transcriptionResult(String, URL)
	case refinementResult(String, URL, TimeInterval)
    case transcriptionError(Error, URL?)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    /// Trivial cleanup work that owns no temp WAV (the discard path's removeItem call).
    /// Safe to cancel when a new recording starts.
    case recordingCleanup
    /// Post-stop work that owns a temp WAV and persists it through transcriptPersistence.
    /// Must NOT be cancelled by handleStartRecording or we leak the temp file or lose the row.
    case recordingFinalize
    case transcription
			case selectedTextRefinement
			case screenContextCapture
			case screenAwareActivation
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
	@Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
	@Dependency(\.uuid) var uuid
  @Dependency(\.transcriptPersistence) var transcriptPersistence
	@Dependency(\.refinement) var refinement
	@Dependency(\.screenCapture) var screenCapture

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing or refining, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
		return handleHotKeyPressed(isBusy: state.isTranscribing || state.isRefining)

      case .hotKeyReleased(.regular):
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording, source: .regular, activeSource: state.activeRecordingSource)

		case .hotKeyReleased(.refined):
				// The reducer owns the recording session, so it is the source of truth for
				// whether this press finishes Screen Aware. This avoids dropping back to a
				// normal refined release when the keyboard monitor has already reset its
				// transient long-press flag while handling the stop press.
				if state.isScreenAwareModeActive {
					return .send(.finishScreenAwareRecording)
				}
				deactivateScreenAwareMode(&state)
				if state.isCapturingSelectedTextForRefinement {
					// A locked refinement session can still be waiting for the selected-text
					// capture that its second tap started. Its third tap must end that
					// session, rather than allowing the delayed capture to start a recording.
					state.refinedHotKeyReleasedWhileCapturingSelection = true
					return .cancel(id: CancelID.screenAwareActivation)
				}
				return .merge(
					.cancel(id: CancelID.screenAwareActivation),
					handleHotKeyReleased(isRecording: state.isRecording, source: .refined, activeSource: state.activeRecordingSource)
				)

			case .refinedHotKeyPressed:
				guard !(state.isTranscribing || state.isRefining) else {
					return handleHotKeyPressed(isBusy: true, startAction: .startRefinedRecording)
				}
				guard state.hexSettings.includeSelectedTextInRefinement else {
					return .send(.startRefinedRecording)
				}
				state.isRefining = false
				state.isCapturingSelectedTextForRefinement = true
				state.refinedHotKeyReleasedWhileCapturingSelection = false
				return .run { [pasteboard] send in
					let selectedText = await pasteboard.captureSelectedText()
					guard !Task.isCancelled else {
						await selectedText?.cancel()
						return
					}
					if let selectedText {
						await send(.selectedTextCaptured(selectedText))
					} else {
						await send(.selectedTextCaptureUnavailable)
					}
				}
				.cancellable(id: CancelID.selectedTextRefinement, cancelInFlight: true)

			case let .startScreenAwareActivationCountdown(activationID):
				guard state.cancelledScreenAwareActivationID != activationID else {
					state.cancelledScreenAwareActivationID = nil
					return .none
				}
				state.screenAwareActivationID = activationID
				let holdDuration = ScreenAwareActivation.holdDuration(for: state.hexSettings)
				return .run { [clock] send in
					try await clock.sleep(for: .seconds(holdDuration))
					await send(.screenAwareModeActivated(activationID))
				}
				.cancellable(id: CancelID.screenAwareActivation, cancelInFlight: true)

			case let .refinedLockEstablished(activationID, isLongPressLocked):
				// A quick second tap starts ordinary refinement only after the lock
				// is established. A held second tap leaves its Screen Aware countdown
				// alive, so it never begins ordinary refinement first.
				if isLongPressLocked {
					// Remember the gesture even if this key-up reaches the reducer before
					// its key-down task has installed the countdown.
					if !state.isScreenAwareModeActive {
						state.screenAwareActivationID = activationID
					}
					return .none
				}
				state.cancelledScreenAwareActivationID = activationID
				if state.screenAwareActivationID == activationID {
					state.screenAwareActivationID = nil
				}
				return .merge(
					.cancel(id: CancelID.screenAwareActivation),
					.send(.refinedHotKeyPressed)
				)

			case let .screenAwareModeActivated(activationID):
				guard state.screenAwareActivationID == activationID else { return .none }
				state.screenAwareActivationID = nil
				let startRecording: Effect<Action>
				if state.isRecording {
					guard state.activeRecordingSource == .refined else { return .none }
					startRecording = .none
				} else {
					startRecording = handleStartRecording(
						&state,
						forcedRefinementMode: .refined,
						source: .refined,
						cancelsScreenContextCapture: false
					)
					guard state.isRecording else { return startRecording }
				}
				state.isScreenAwareModeActive = true
				state.screenAwareInputSourceForRefinement = state.hexSettings.screenAwareInputSource
				let captureID = uuid()
				state.screenContextCaptureID = captureID
				state.pendingScreenAwareTranscription = nil
				let captureScreen = Effect<Action>.run { [screenCapture] send in
					do {
						let context = try await screenCapture.captureDisplayUnderCursor {}
						await send(.screenContextCaptured(captureID, context))
					} catch is CancellationError {
						return
					} catch {
						await send(.screenContextCaptureFailed(captureID, error))
					}
				}
				.cancellable(id: CancelID.screenContextCapture, cancelInFlight: true)
				return .merge(startRecording, captureScreen)

				case .finishRecordingWithRefinement:
				// This action is emitted for a single press of the refinement shortcut only
				// while the regular hotkey still owns an active recording. Preserve the
				// original session's timing rules, but refine its resulting transcript.
				guard state.isRecording, state.activeRecordingSource == .regular else { return .none }
					state.forcedRefinementMode = .refined
					return .send(.stopRecording)

				case .finishScreenAwareRecording:
					if state.isCapturingSelectedTextForRefinement {
						deactivateScreenAwareMode(&state)
						state.refinedHotKeyReleasedWhileCapturingSelection = true
						return .cancel(id: CancelID.screenAwareActivation)
					}
					guard state.isRecording, state.activeRecordingSource == .refined else {
						deactivateScreenAwareMode(&state)
						return .cancel(id: CancelID.screenAwareActivation)
					}
					deactivateScreenAwareMode(&state)
					return .merge(
						.cancel(id: CancelID.screenAwareActivation),
						.send(.stopRecording)
					)

				case let .screenContextCaptured(captureID, context):
					guard state.screenContextCaptureID == captureID else { return .none }
					state.screenContextCaptureID = nil
					state.screenContextCaptureErrorMessage = nil
					state.screenContextForRefinement = context
					let persistScreenshot: Effect<Action> = if state.hexSettings.saveTranscriptionHistory {
						.run { [transcriptPersistence] send in
							do {
								let path = try await transcriptPersistence.saveScreenshot(context.imagePNGData)
								await send(.screenContextArtifactPersisted(captureID, path))
							} catch {
								transcriptionFeatureLogger.error("Failed to persist screen context: \(error.localizedDescription, privacy: .private)")
							}
						}
					} else {
						.none
					}
					guard let pending = state.pendingScreenAwareTranscription else { return persistScreenshot }
					deactivateScreenAwareMode(&state)
					state.pendingScreenAwareTranscription = nil
					return .merge(
						persistScreenshot,
						beginRefinement(
							&state,
							text: pending.text,
							audioURL: pending.audioURL,
							duration: pending.duration,
							screenContext: context
						)
					)

				case let .screenContextArtifactPersisted(captureID, screenshotPath):
					// Capture IDs prevent a late image from a cancelled run being attached to
					// a newer recording. Once the context was accepted, the image is already
					// a durable artifact even if audio is still being recorded.
					guard state.screenContextForRefinement != nil || state.screenContextCaptureID == captureID else {
						return .run { _ in try? FileManager.default.removeItem(at: screenshotPath) }
					}
					var shouldKeepStagedScreenshot = true
					if let historyID = state.activeHistoryTranscriptID,
					   let context = state.screenContextForRefinement {
						state.$transcriptionHistory.withLock { history in
							guard let index = history.history.firstIndex(where: { $0.id == historyID }) else { return }
							guard history.history[index].screenshotPath == nil else {
								shouldKeepStagedScreenshot = false
								return
							}
							history.history[index].screenshotPath = screenshotPath
							history.history[index].screenshotByteCount = context.imagePNGData.count
							history.history[index].screenshotRecognizedText = context.recognizedText
							history.history[index].screenAwareInputSource = state.screenAwareInputSourceForRefinement
						}
					}
					guard shouldKeepStagedScreenshot else {
						return .run { _ in try? FileManager.default.removeItem(at: screenshotPath) }
					}
					state.stagedScreenContextScreenshotPath = screenshotPath
					return .none

				case let .screenContextCaptureFailed(captureID, error):
					guard state.screenContextCaptureID == captureID else { return .none }
					deactivateScreenAwareMode(&state)
					state.screenContextCaptureID = nil
					state.screenContextForRefinement = nil
					state.screenContextCaptureErrorMessage = error.localizedDescription
					transcriptionFeatureLogger.warning("Screen context capture failed: \(error.localizedDescription, privacy: .private)")
					guard !state.isRecording else { return .none }
					guard let pending = state.pendingScreenAwareTranscription else { return .none }
					state.pendingScreenAwareTranscription = nil
					return beginRefinement(
						&state,
						text: pending.text,
						audioURL: pending.audioURL,
						duration: pending.duration,
						screenContext: nil
					)

			case .selectedTextCaptureUnavailable:
				let refinedHotKeyWasReleased = state.refinedHotKeyReleasedWhileCapturingSelection
				state.isCapturingSelectedTextForRefinement = false
				state.refinedHotKeyReleasedWhileCapturingSelection = false
				return refinedHotKeyWasReleased ? .none : .send(.startRefinedRecording)

			case let .selectedTextCaptured(selectedText):
				let refinedHotKeyWasReleased = state.refinedHotKeyReleasedWhileCapturingSelection
				state.isCapturingSelectedTextForRefinement = false
				state.refinedHotKeyReleasedWhileCapturingSelection = false
				guard !refinedHotKeyWasReleased else {
					return .run { _ in await selectedText.cancel() }
				}
				state.selectedTextForRefinement = selectedText
				return .send(.startRefinedRecording)

      // MARK: - Recording Flow

      case .startRecording:
		return handleStartRecording(&state, source: .regular)

		case .startRefinedRecording:
			return handleStartRecording(&state, forcedRefinementMode: .refined, source: .refined)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionAudioCaptured(audioURL, duration):
        state.activeTranscriptionAudioURL = audioURL
        state.activeTranscriptionDuration = duration
        return .none

		case let .transcriptionCheckpointPersisted(transcript):
			state.activeHistoryTranscriptID = transcript.id
			// The audio has already moved to durable storage. Insert its matching History
			// row in this reducer turn so the transcript, screenshot, result, cancellation,
			// or error actions that follow can always update the same durable run.
			let artifactsToDelete = state.$transcriptionHistory.withLock { history -> [Transcript] in
				var artifactsToDelete: [Transcript] = []
				history.history.insert(transcript, at: 0)
				if let maximumEntries = state.hexSettings.maxHistoryEntries, maximumEntries > 0 {
					while history.history.count > maximumEntries, let removedTranscript = history.history.popLast() {
						if !history.history.contains(where: { $0.audioPath == removedTranscript.audioPath }) {
							artifactsToDelete.append(removedTranscript)
						}
					}
				}
				return artifactsToDelete
			}
			return .run { _ in
				for transcript in artifactsToDelete {
					try? await transcriptPersistence.deleteArtifacts(transcript)
				}
			}

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

	  case let .refinementResult(result, audioURL, duration):
		return handleRefinementResult(&state, result: result, audioURL: audioURL, duration: duration)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing || state.isRefining || state.isCapturingSelectedTextForRefinement else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)

		case let .hotKeyCancelled(source):
			guard state.activeRecordingSource == source
				|| (source == .refined && state.isCapturingSelectedTextForRefinement)
			else { return .none }
			return handleCancel(&state)

		case let .hotKeyDiscarded(source):
			guard state.activeRecordingSource == source, state.isRecording else { return .none }
			return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
		var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
		var refinedHotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: []))
		var pendingScreenAwareGestureID: UUID?
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
		@Shared(.isSettingRefinedHotKey) var isSettingRefinedHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
		if isSettingHotKey || isSettingRefinedHotKey {
          return false
        }

		let refinedHotkey = hexSettings.refinedHotkey
		let shouldMonitorRefinedHotkey = refinedHotkey.map { !$0.conflicts(with: hexSettings.hotkey) } ?? false
		if let refinedHotkey, shouldMonitorRefinedHotkey {
			refinedHotKeyProcessor.hotkey = refinedHotkey
			refinedHotKeyProcessor.doubleTapLockEnabled = hexSettings.refinedDoubleTapLockEnabled
			let usesScreenAwareDoubleTapActivation = hexSettings.refinedDoubleTapLockEnabled
				&& ScreenAwareActivation.isAvailable(with: hexSettings)
			// Screen Aware reserves the held second tap. This deliberately makes the
			// first tap inert even when the separate "Use double-tap only" preference
			// is off, so double-tap lock has one unambiguous Screen Aware sequence.
			refinedHotKeyProcessor.useDoubleTapOnly = hexSettings.refinedDoubleTapLockEnabled
				&& (hexSettings.refinedUseDoubleTapOnly || usesScreenAwareDoubleTapActivation)
			let shouldMeasureSecondTapForScreenAware = usesScreenAwareDoubleTapActivation
			// With double-tap lock enabled, Screen Aware activates only while the
			// second tap is held. Its release enters the usual refinement lock state.
			refinedHotKeyProcessor.lockingHoldDuration = shouldMeasureSecondTapForScreenAware
				? ScreenAwareActivation.holdDuration(for: hexSettings)
				: nil
			refinedHotKeyProcessor.minimumKeyTime = hexSettings.refinedMinimumKeyTime
		}

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
			if let refinedHotkey,
				hotKeyProcessor.isMatched,
				keyEvent.key == refinedHotkey.key,
				keyEvent.modifiers.matchesExactly(refinedHotkey.modifiers)
			{
				// While a regular recording is active, one press of the refinement hotkey
				// finishes that recording. Do not feed this press to the refinement processor:
				// its double-tap tracker must remain untouched for the next recording. Reset
				// the regular processor as well, otherwise a double-tap lock would keep
				// intercepting every future refinement-hotkey press.
				hotKeyProcessor.reset()
				Task { await send(.finishRecordingWithRefinement) }
				return true
			}
				if shouldMonitorRefinedHotkey {
					switch refinedHotKeyProcessor.process(keyEvent: keyEvent) {
				case .startRecording:
					let shouldDeferRefinementForScreenAware = refinedHotKeyProcessor.isLockingHold
					let screenAwareGestureID = shouldDeferRefinementForScreenAware ? UUID() : nil
					pendingScreenAwareGestureID = screenAwareGestureID
					Task {
						guard shouldDeferRefinementForScreenAware else {
							await send(.refinedHotKeyPressed)
							return
						}
						guard let screenAwareGestureID else { return }
						await send(.startScreenAwareActivationCountdown(screenAwareGestureID))
					}
					return refinedHotKeyProcessor.useDoubleTapOnly || keyEvent.key != nil
					case .stopRecording:
						// Let the reducer route the finish according to the session it owns.
						// `isLongPressLocked` is reset by this stop event, so using it here
						// made Screen Aware's final press timing-sensitive.
						Task { await send(.hotKeyReleased(.refined)) }
					return false
				case .locked:
					let isLongPressLocked = refinedHotKeyProcessor.isLongPressLocked
					let screenAwareGestureID = pendingScreenAwareGestureID
					pendingScreenAwareGestureID = nil
					Task {
						guard let screenAwareGestureID else { return }
						await send(.refinedLockEstablished(screenAwareGestureID, isLongPressLocked))
					}
					return false
				case .cancel:
					pendingScreenAwareGestureID = nil
					Task { await send(.hotKeyCancelled(.refined)) }
					return true
				case .discard:
					pendingScreenAwareGestureID = nil
					Task { await send(.hotKeyDiscarded(.refined)) }
					return false
				case .none:
					break
				}
			}
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

		  // Process the key event
		  switch hotKeyProcessor.process(keyEvent: keyEvent) {
		  case .startRecording:
			Task { await send(.hotKeyPressed) }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

		  case .stopRecording:
			Task { await send(.hotKeyReleased(.regular)) }
            return false // or `true` if you want to intercept

		  case .locked:
			return false

		  case .cancel:
			Task { await send(.hotKeyCancelled(.regular)) }
            return true

		  case .discard:
			Task { await send(.hotKeyDiscarded(.regular)) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
			if shouldMonitorRefinedHotkey, refinedHotKeyProcessor.state != .idle {
				switch refinedHotKeyProcessor.processMouseClick() {
				case .cancel: Task { await send(.hotKeyCancelled(.refined)) }
				case .discard: Task { await send(.hotKeyDiscarded(.refined)) }
				case .startRecording, .stopRecording, .locked, .none: break
				}
				return false
			}
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
		  case .cancel:
			Task { await send(.hotKeyCancelled(.regular)) }
            return false // Don't intercept the click itself
		  case .discard:
			Task { await send(.hotKeyDiscarded(.regular)) }
            return false // Don't intercept the click itself
		  case .startRecording, .stopRecording, .locked, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isBusy: Bool, startAction: Action = .startRecording) -> Effect<Action> {
	// If already transcribing or refining, cancel first. Otherwise start recording immediately.
	guard isBusy else { return .send(startAction) }
    return .concatenate(
      .send(.cancel),
		.send(startAction)
    )
  }

  func handleHotKeyReleased(isRecording: Bool, source: RecordingSource, activeSource: RecordingSource?) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording && source == activeSource ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
	func deactivateScreenAwareMode(_ state: inout State) {
		if let activationID = state.screenAwareActivationID {
			state.cancelledScreenAwareActivationID = activationID
		}
		state.screenAwareActivationID = nil
		guard state.isScreenAwareModeActive else { return }
		state.isScreenAwareModeActive = false
	}

  func handleStartRecording(
	_ state: inout State,
	forcedRefinementMode: RefinementMode? = nil,
	source: RecordingSource,
	cancelsScreenContextCapture: Bool = true
  ) -> Effect<Action> {
    guard !state.isRecording else { return .none }
    guard state.modelBootstrapState.isModelReady else {
		let selectedText = state.selectedTextForRefinement
		state.selectedTextForRefinement = nil
      return .merge(
        .send(.modelMissing),
			.run { _ in
				await selectedText?.cancel()
				soundEffect.play(.cancel)
			}
      )
    }
	state.isRecording = true
	state.originalTranscriptForRefinement = nil
		state.outputGenerationStartTime = nil
		state.screenContextForRefinement = nil
		state.screenAwareInputSourceForRefinement = nil
		state.stagedScreenContextScreenshotPath = nil
		state.activeHistoryTranscriptID = nil
			state.screenContextCaptureID = nil
			state.screenContextCaptureErrorMessage = nil
			state.pendingScreenAwareTranscription = nil
		state.forcedRefinementMode = forcedRefinementMode
		state.activeRecordingHotkey = forcedRefinementMode == nil ? state.hexSettings.hotkey : state.hexSettings.refinedHotkey
		state.activeMinimumKeyTime = forcedRefinementMode == nil ? state.hexSettings.minimumKeyTime : state.hexSettings.refinedMinimumKeyTime
		state.activeRecordingSource = source
    let startTime = now
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
			.cancel(id: CancelID.recordingCleanup),
			cancelsScreenContextCapture ? .cancel(id: CancelID.screenContextCapture) : .none,
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }
        await recording.startRecording()
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
			hotkey: state.activeRecordingHotkey ?? state.hexSettings.hotkey,
			minimumKeyTime: state.activeMinimumKeyTime ?? state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
		let minimumKeyTime = state.activeMinimumKeyTime ?? state.hexSettings.minimumKeyTime
		let hotkeyHasKey = (state.activeRecordingHotkey ?? state.hexSettings.hotkey).key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

	// The long-press gesture has already cleared its own activation threshold. Selected-text
	// capture can delay the microphone start, so do not discard an otherwise valid
	// screen-aware request merely because the recorded-audio duration is shorter.
	let screenAwareCaptureInFlight = state.screenContextCaptureID != nil
    guard decision == .proceedToTranscription || screenAwareCaptureInFlight else {
		let selectedText = state.selectedTextForRefinement
			state.selectedTextForRefinement = nil
			state.screenContextForRefinement = nil
			state.screenContextCaptureID = nil
			state.pendingScreenAwareTranscription = nil
			state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
      // Recording was below minimum duration. If it captured at least 1.0s of audio we still
      // persist it as a cancelled entry so the user can retry; otherwise discard silently
      // (covers accidental modifier-only taps).
      transcriptionFeatureLogger.notice("Short recording per decision \(String(describing: decision)); duration=\(String(format: "%.3f", duration))s")
      let sourceAppBundleID = state.sourceAppBundleID
      let sourceAppName = state.sourceAppName
      let transcriptionHistory = state.$transcriptionHistory
	      return .merge(
	        .cancel(id: CancelID.recordingStart),
			.cancel(id: CancelID.screenContextCapture),
        .run { [duration, sleepManagement] _ in
			await selectedText?.cancel()
          await sleepManagement.allowSleep()
          let stopResult = await recording.stopRecording()
          guard !Task.isCancelled else { return }
          guard case let .captured(url) = stopResult else { return }
          await persistOrDiscard(
            status: .cancelled,
            audioURL: url,
            duration: duration,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            transcriptionHistory: transcriptionHistory
          )
        }
        // Don't cancelInFlight here: a second finalize firing (rare hotkey-release + ESC
        // race) must not abort an already-running persist between recording.stopRecording()
        // and persistOrDiscard completing, or we leak the temp WAV / lose the row.
        .cancellable(id: CancelID.recordingFinalize)
      )
    }

    let model = state.hexSettings.selectedModel
    guard !model.isEmpty else {
      // Defense-in-depth: handleStartRecording already blocks recording when the
      // bootstrap state says no model is ready, but settings can change while a
      // recording is in flight (or the in-memory bootstrap default can race a
      // cold launch). Never hand an empty model name to the transcriber: it
      // silently produces nothing (or junk like "[BLANK_AUDIO]").
      transcriptionFeatureLogger.error("Recording stopped with no transcription model selected; discarding audio")
      return .merge(
        handleDiscard(&state),
        .send(.modelMissing)
      )
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true
	let shouldCreateHistoryCheckpoint = state.hexSettings.saveTranscriptionHistory
	let selectedTextForCheckpoint = state.selectedTextForRefinement?.text
	let screenContextForCheckpoint = state.screenContextForRefinement
	let screenAwareInputSourceForCheckpoint = state.screenAwareInputSourceForRefinement
	let stagedScreenshotPath = state.stagedScreenContextScreenshotPath
	let sourceAppBundleID = state.sourceAppBundleID
	let sourceAppName = state.sourceAppName

    return .merge(
      .cancel(id: CancelID.recordingStart),
		.run { [duration, sleepManagement, transcriptPersistence] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        var unownedAudioURL: URL?
        var capturedAudioURL: URL?
        defer {
          if let unownedAudioURL {
            FileManager.default.removeItemIfExists(at: unownedAudioURL)
          }
        }
        do {
          let stopResult = await recording.stopRecording()
          let capturedURL: URL
          switch stopResult {
          case let .captured(url):
            capturedURL = url
          case .ignored(.staleSession):
            transcriptionFeatureLogger.notice("Ignoring transcription stop superseded by a newer recording session")
            return
          case .ignored(.noActiveRecording):
            transcriptionFeatureLogger.error("Recording stopped without captured audio")
            await send(.transcriptionError(RecordingFailure.noCapturedAudio, nil))
            return
          case let .failed(error):
            transcriptionFeatureLogger.error("Recording stop failed: \(error.localizedDescription)")
            await send(.transcriptionError(error, nil))
            return
          }
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)
		  unownedAudioURL = capturedURL
		  capturedAudioURL = capturedURL
		  var audioURLForTranscription = capturedURL

		  // The audio file is the first durable checkpoint. It is stored before
		  // transcription begins, so a crash, cancellation, or provider failure can
		  // never discard the voice message that produced the run.
		  if shouldCreateHistoryCheckpoint {
			  do {
				  let checkpoint = try await transcriptPersistence.save(.init(
					  text: "",
					  audioURL: capturedURL,
					  duration: duration,
					  sourceAppBundleID: sourceAppBundleID,
					  sourceAppName: sourceAppName,
					  status: .processing,
					  screenshotData: stagedScreenshotPath == nil ? screenContextForCheckpoint?.imagePNGData : nil,
					  screenshotPath: stagedScreenshotPath,
					  selectedText: selectedTextForCheckpoint,
					  screenshotRecognizedText: screenContextForCheckpoint?.recognizedText,
					  screenAwareInputSource: screenAwareInputSourceForCheckpoint
				  ))
				  audioURLForTranscription = checkpoint.audioPath
				  capturedAudioURL = checkpoint.audioPath
				  unownedAudioURL = nil
				  await send(.transcriptionCheckpointPersisted(checkpoint))
			  } catch {
				  transcriptionFeatureLogger.error("Failed to persist audio checkpoint: \(error.localizedDescription, privacy: .private)")
			  }
		  }

          // Synchronously plumb the captured URL + accurate duration into state so cancel
          // and ownership-guard paths can see them.
		  await send(.transcriptionAudioCaptured(audioURLForTranscription, duration))
		  if audioURLForTranscription != capturedURL {
			  unownedAudioURL = nil
		  }
          guard !Task.isCancelled else { return }

          // Create transcription options with the selected language
          // Note: cap concurrency to avoid audio I/O overloads on some Macs
          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil, // Only auto-detect if no language specified
            chunkingStrategy: .vad,
          )

		  let result = try await transcription.transcribe(audioURLForTranscription, model, decodeOptions) { _ in }

		  transcriptionFeatureLogger.notice("Transcribed audio from \(audioURLForTranscription.lastPathComponent, privacy: .private) to text length \(result.count)")
		  await send(.transcriptionResult(result, audioURLForTranscription))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription, privacy: .private)")
          await send(.transcriptionError(error, capturedAudioURL))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  /// Finish an empty local transcription without deleting the audio checkpoint that was
  /// persisted before transcription began. This leaves an inspectable, retryable run in
  /// History instead of making a completed recording disappear.
  func handleEmptyTranscriptionResult(
    _ state: inout State,
    audioURL: URL
  ) -> Effect<Action> {
    let historyCheckpointID = state.activeHistoryTranscriptID
    state.activeHistoryTranscriptID = nil
    state.activeTranscriptionAudioURL = nil
    state.activeTranscriptionDuration = nil
    state.screenContextForRefinement = nil
    state.screenContextCaptureID = nil
    state.pendingScreenAwareTranscription = nil
    state.forcedRefinementMode = nil
    state.activeRecordingHotkey = nil
    state.activeMinimumKeyTime = nil
    state.activeRecordingSource = nil

    if let historyCheckpointID {
      state.$transcriptionHistory.withLock { history in
        guard let index = history.history.firstIndex(where: { $0.id == historyCheckpointID }) else { return }
        var checkpoint = history.history[index]
        checkpoint.processingErrors = [.init(
          stage: .transcription,
          message: "No transcription was produced."
        )]
        checkpoint.status = .failed
        history.history[index] = checkpoint
      }
      return .cancel(id: CancelID.screenContextCapture)
    }

    return .merge(
      .cancel(id: CancelID.screenContextCapture),
      .run { _ in FileManager.default.removeItemIfExists(at: audioURL) }
    )
  }

  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL
  ) -> Effect<Action> {
    // Ownership guard MUST be first: drop late-arriving results from a cancelled transcription
    // before any state mutation, force-quit detection, empty-result handling, post-processing,
    // or side effects.
    guard state.activeTranscriptionAudioURL == audioURL else {
      return .none
    }
    let duration = state.activeTranscriptionDuration
      ?? state.recordingStartTime.map { now.timeIntervalSince($0) }
      ?? 0

    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
		  state.activeTranscriptionAudioURL = nil
		  state.activeTranscriptionDuration = nil
		  state.screenContextForRefinement = nil
		  state.screenContextCaptureID = nil
		  state.pendingScreenAwareTranscription = nil
	  state.forcedRefinementMode = nil
	  state.activeRecordingHotkey = nil
	  state.activeMinimumKeyTime = nil
	  state.activeRecordingSource = nil
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
	      return .merge(
			.cancel(id: CancelID.screenContextCapture),
			.run { _ in
				FileManager.default.removeItemIfExists(at: audioURL)
				await MainActor.run {
					NSApp.terminate(nil)
				}
			}
		  )
    }

    let selectedText = state.selectedTextForRefinement
		let screenContext = state.screenContextForRefinement

    // A silent selected-text recording still has useful work to do: apply the configured
    // refinement prompt to the captured selection without an extra spoken instruction.
    guard !result.isEmpty || selectedText != nil || screenContext != nil || state.screenContextCaptureID != nil else {
      return handleEmptyTranscriptionResult(&state, audioURL: audioURL)
    }

    if !result.isEmpty {
      transcriptionFeatureLogger.info("Raw transcription: '\(result, privacy: .private)'")
    }
    let modifiedResult: String
    if result.isEmpty || state.isRemappingScratchpadFocused {
      modifiedResult = result
    } else {
      let settings = state.hexSettings
      let remapped = WordRemappingApplier.apply(result, remappings: settings.wordRemappings)
      let removed = settings.wordRemovalsEnabled
        ? WordRemovalApplier.apply(remapped, removals: settings.wordRemovals)
        : remapped
      modifiedResult = TranscriptFormattingApplier.apply(
        removed,
        lowercase: settings.lowercaseTranscripts,
        removePunctuation: settings.removePunctuation
      )
    }
    if modifiedResult != result {
      transcriptionFeatureLogger.info("Applied word filters; processed length=\(modifiedResult.count)")
    } else if state.isRemappingScratchpadFocused {
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    }

    // Empty after post-processing: keep the same durable checkpoint as an error.
    guard !modifiedResult.isEmpty || selectedText != nil || screenContext != nil || state.screenContextCaptureID != nil else {
      return handleEmptyTranscriptionResult(&state, audioURL: audioURL)
    }

		// The ordinary hotkey always produces the normal transcription. Only the
		// dedicated refined-transcription hotkey enables downstream AI processing.
		let refinementMode = state.forcedRefinementMode ?? .raw
	    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory
		// Local transcription is independently durable before optional AI work begins.
		if let historyCheckpointID = state.activeHistoryTranscriptID {
			state.$transcriptionHistory.withLock { history in
				guard let index = history.history.firstIndex(where: { $0.id == historyCheckpointID }) else { return }
				history.history[index].rawText = modifiedResult
				history.history[index].selectedText = selectedText?.text ?? history.history[index].selectedText
			}
		}

	// Refinement is intentionally downstream-only: it receives the existing final transcript
	// text and never participates in capture, transcription, or audio ownership.
	guard refinementMode != .raw else {
		let historyCheckpointID = state.activeHistoryTranscriptID
		state.activeHistoryTranscriptID = nil
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
		state.activeTranscriptionAudioURL = nil
		state.activeTranscriptionDuration = nil
		return finalizeTranscriptEffect(
			result: modifiedResult,
			duration: duration,
			sourceAppBundleID: sourceAppBundleID,
			sourceAppName: sourceAppName,
			audioURL: audioURL,
			transcriptionHistory: transcriptionHistory,
			selectedText: selectedText,
			rawTranscript: modifiedResult,
			historyCheckpointID: historyCheckpointID
		)
	}

		if screenContext == nil, state.screenContextCaptureID != nil {
			state.originalTranscriptForRefinement = modifiedResult.isEmpty ? nil : modifiedResult
			state.pendingScreenAwareTranscription = .init(
				text: modifiedResult,
				audioURL: audioURL,
				duration: duration
			)
			state.isRefining = true
			return .none
		}

		return beginRefinement(
			&state,
			text: modifiedResult,
			audioURL: audioURL,
			duration: duration,
			screenContext: screenContext
		)
	  }

	func beginRefinement(
		_ state: inout State,
		text: String,
		audioURL: URL,
		duration: TimeInterval,
		screenContext: ScreenContext?
	) -> Effect<Action> {
		guard state.activeTranscriptionAudioURL == audioURL else { return .none }
		let settings = state.hexSettings
		let selectedText = state.selectedTextForRefinement
		let refinementInput = selectedText?.text ?? text
		let spokenInstruction = selectedText == nil ? nil : text
		let request = { () -> RefinementRequest in
			if let screenContext {
				let imageModelID = state.screenAwareInputSourceForRefinement?.uploadsScreenshot == true
					? OpenRouterModelCatalog.selectedImageCapableModelID(for: settings)
					: nil
				return settings.screenAwareRequest(
					for: text,
					context: screenContext,
					inputSource: state.screenAwareInputSourceForRefinement,
					imageModelID: imageModelID
				)
			}
			return settings.refinementRequest(
				for: refinementInput,
				mode: state.forcedRefinementMode ?? .refined,
				spokenInstruction: spokenInstruction
			)
		}()
		state.originalTranscriptForRefinement = text.isEmpty ? nil : text
		state.isRefining = true
		state.outputGenerationStartTime = now
		return .run { [refinement] send in
			do {
				let refinedResult = try await refinement.refine(request)
				try Task.checkCancellation()
				await send(.refinementResult(refinedResult, audioURL, duration))
			} catch is CancellationError {
				return
			} catch {
				transcriptionFeatureLogger.warning("Refinement failed: \(error.localizedDescription, privacy: .private)")
				await send(.transcriptionError(error, audioURL))
			}
		}
		.cancellable(id: CancelID.transcription)
	}

  func handleRefinementResult(
	_ state: inout State,
	result: String,
	audioURL: URL,
	duration: TimeInterval
  ) -> Effect<Action> {
	// The audio URL remains owned by the active session while refinement runs. This makes
	// cancellation retain the exact same persistence semantics as a normal transcription.
	guard state.activeTranscriptionAudioURL == audioURL else { return .none }
	state.activeTranscriptionAudioURL = nil
	state.activeTranscriptionDuration = nil
	state.isRefining = false
		let outputGenerationDuration = state.outputGenerationStartTime.map { now.timeIntervalSince($0) }
		state.outputGenerationStartTime = nil
		state.isCapturingSelectedTextForRefinement = false
		state.refinedHotKeyReleasedWhileCapturingSelection = false
		let selectedText = state.selectedTextForRefinement
		state.selectedTextForRefinement = nil
			let originalTranscript = state.originalTranscriptForRefinement
			state.originalTranscriptForRefinement = nil
			let screenContext = state.screenContextForRefinement
			state.screenContextForRefinement = nil
			let screenAwareInputSource = state.screenAwareInputSourceForRefinement
			state.screenAwareInputSourceForRefinement = nil
			let screenContextCaptureErrorMessage = state.screenContextCaptureErrorMessage
			state.screenContextCaptureErrorMessage = nil
			state.screenContextCaptureID = nil
			state.pendingScreenAwareTranscription = nil
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil

	let sourceAppBundleID = state.sourceAppBundleID
	let sourceAppName = state.sourceAppName
	let transcriptionHistory = state.$transcriptionHistory
	let historyCheckpointID = state.activeHistoryTranscriptID
	state.activeHistoryTranscriptID = nil
	return finalizeTranscriptEffect(
		result: result,
		duration: duration,
		sourceAppBundleID: sourceAppBundleID,
		sourceAppName: sourceAppName,
		audioURL: audioURL,
			transcriptionHistory: transcriptionHistory,
			selectedText: selectedText,
			originalTranscript: originalTranscript,
			rawTranscript: originalTranscript ?? result,
			screenshotData: screenContext?.imagePNGData,
			screenshotRecognizedText: screenContext?.recognizedText,
			processingErrors: screenContextCaptureErrorMessage.map {
				[.init(stage: .screenContext, message: $0)]
			},
			wasRefined: true,
			outputGenerationDuration: outputGenerationDuration,
			screenAwareInputSource: screenAwareInputSource,
			historyCheckpointID: historyCheckpointID
	)
  }

	func finalizeTranscriptEffect(
		result: String,
		duration: TimeInterval,
		sourceAppBundleID: String?,
		sourceAppName: String?,
		audioURL: URL,
			transcriptionHistory: Shared<TranscriptionHistory>,
			selectedText: SelectedTextCapture? = nil,
			originalTranscript: String? = nil,
			rawTranscript: String? = nil,
			screenshotData: Data? = nil,
			screenshotRecognizedText: String? = nil,
			processingErrors: [TranscriptProcessingError]? = nil,
			wasRefined: Bool? = nil,
			outputGenerationDuration: TimeInterval? = nil,
			screenAwareInputSource: ScreenAwareInputSource? = nil,
			historyCheckpointID: UUID? = nil
	) -> Effect<Action> {
		.run { _ in
			await finalizeRecordingAndStoreTranscript(
				result: result,
				duration: duration,
				sourceAppBundleID: sourceAppBundleID,
				sourceAppName: sourceAppName,
				audioURL: audioURL,
					transcriptionHistory: transcriptionHistory,
					selectedText: selectedText,
					originalTranscript: originalTranscript,
					rawTranscript: rawTranscript,
					screenshotData: screenshotData,
					screenshotRecognizedText: screenshotRecognizedText,
					processingErrors: processingErrors,
					wasRefined: wasRefined,
					outputGenerationDuration: outputGenerationDuration,
					screenAwareInputSource: screenAwareInputSource,
					historyCheckpointID: historyCheckpointID
			)
		}
		.cancellable(id: CancelID.transcription)
	}

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    // Ownership guard FIRST: drop late-arriving errors that don't belong to the
    // active session. Symmetric optional comparison covers all four nil/non-nil
    // pairings — most importantly it stops a stale nil-URL error from clearing
    // a newer session's activeTranscriptionAudioURL.
    guard state.activeTranscriptionAudioURL == audioURL else {
      return .none
    }
    let duration = state.activeTranscriptionDuration
      ?? state.recordingStartTime.map { now.timeIntervalSince($0) }
      ?? 0
    state.activeTranscriptionAudioURL = nil
    state.activeTranscriptionDuration = nil
	let historyCheckpointID = state.activeHistoryTranscriptID
	state.activeHistoryTranscriptID = nil

    state.isTranscribing = false
	let failedDuringRefinement = state.isRefining
	state.isRefining = false
		let outputGenerationDuration = failedDuringRefinement
			? state.outputGenerationStartTime.map { now.timeIntervalSince($0) }
			: nil
		state.outputGenerationStartTime = nil
		deactivateScreenAwareMode(&state)
			let selectedText = state.selectedTextForRefinement
			state.selectedTextForRefinement = nil
			let originalTranscript = state.originalTranscriptForRefinement
			state.originalTranscriptForRefinement = nil
			let screenContext = state.screenContextForRefinement
			state.screenContextForRefinement = nil
			let screenContextCaptureErrorMessage = state.screenContextCaptureErrorMessage
			state.screenContextCaptureErrorMessage = nil
			state.screenContextCaptureID = nil
			state.pendingScreenAwareTranscription = nil
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
    state.isPrewarming = false
    state.error = error.localizedDescription

    guard let audioURL else {
			return .merge(
				.cancel(id: CancelID.screenContextCapture),
				.run { _ in await selectedText?.cancel() }
			)
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

	return .merge(
		.cancel(id: CancelID.screenContextCapture),
		.run { _ in
			await selectedText?.cancel()
			let processingErrors = (screenContextCaptureErrorMessage.map {
				[TranscriptProcessingError(stage: .screenContext, message: $0)]
			} ?? []) + [.init(
				stage: failedDuringRefinement ? .processing : .transcription,
				message: error.localizedDescription
			)]
			if let historyCheckpointID {
				transcriptionHistory.withLock { history in
					guard let index = history.history.firstIndex(where: { $0.id == historyCheckpointID }) else { return }
					var checkpoint = history.history[index]
					checkpoint.text = failedDuringRefinement ? "" : (originalTranscript ?? "")
					checkpoint.rawText = originalTranscript ?? checkpoint.rawText
					checkpoint.selectedText = selectedText?.text ?? checkpoint.selectedText
					checkpoint.screenshotRecognizedText = screenContext?.recognizedText ?? checkpoint.screenshotRecognizedText
					checkpoint.processingErrors = processingErrors
					checkpoint.wasRefined = failedDuringRefinement
					checkpoint.outputGenerationDuration = outputGenerationDuration
					checkpoint.status = .failed
					history.history[index] = checkpoint
				}
			} else {
				await persistOrDiscard(
					status: .failed,
					audioURL: audioURL,
					duration: duration,
					sourceAppBundleID: sourceAppBundleID,
					sourceAppName: sourceAppName,
					transcriptionHistory: transcriptionHistory,
					screenshotData: screenContext?.imagePNGData,
					text: failedDuringRefinement ? "" : (originalTranscript ?? ""),
					rawText: originalTranscript,
					selectedText: selectedText?.text,
					screenshotRecognizedText: screenContext?.recognizedText,
					processingErrors: processingErrors,
					wasRefined: failedDuringRefinement,
					outputGenerationDuration: outputGenerationDuration
				)
			}
		}
	)
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  /// Storage failures are logged but do not block the paste — the transcription succeeded
  /// from the user's perspective and they should still get their text.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
			audioURL: URL,
			transcriptionHistory: Shared<TranscriptionHistory>,
			selectedText: SelectedTextCapture? = nil,
			originalTranscript: String? = nil,
			rawTranscript: String? = nil,
			screenshotData: Data? = nil,
			screenshotRecognizedText: String? = nil,
			processingErrors: [TranscriptProcessingError]? = nil,
			wasRefined: Bool? = nil,
			outputGenerationDuration: TimeInterval? = nil,
			screenAwareInputSource: ScreenAwareInputSource? = nil,
			historyCheckpointID: UUID? = nil
  ) async {
    @Shared(.hexSettings) var hexSettings: HexSettings

	let selectionReplacementResult: SelectedTextReplacementResult? = if let selectedText {
		await selectedText.replace(with: result)
	} else {
		nil
	}

    if let historyCheckpointID {
		var screenshotPath: URL?
		if let screenshotData {
			let existingScreenshotPath = transcriptionHistory.withLock { history in
				history.history.first(where: { $0.id == historyCheckpointID })?.screenshotPath
			}
			screenshotPath = existingScreenshotPath
			if existingScreenshotPath == nil {
				screenshotPath = try? await transcriptPersistence.saveScreenshot(screenshotData)
			}
		}
		transcriptionHistory.withLock { history in
			guard let index = history.history.firstIndex(where: { $0.id == historyCheckpointID }) else { return }
			var checkpoint = history.history[index]
			checkpoint.text = result
			checkpoint.rawText = rawTranscript ?? originalTranscript ?? result
			checkpoint.selectedText = selectedText?.text ?? checkpoint.selectedText
			checkpoint.screenshotPath = screenshotPath ?? checkpoint.screenshotPath
			checkpoint.screenshotByteCount = screenshotData?.count ?? checkpoint.screenshotByteCount
			checkpoint.screenshotRecognizedText = screenshotRecognizedText ?? checkpoint.screenshotRecognizedText
			checkpoint.processingErrors = processingErrors
			checkpoint.wasRefined = wasRefined
			checkpoint.outputGenerationDuration = outputGenerationDuration
			checkpoint.screenAwareInputSource = screenAwareInputSource ?? checkpoint.screenAwareInputSource
			checkpoint.status = .completed
			history.history[index] = checkpoint
		}
    } else if hexSettings.saveTranscriptionHistory {
      do {
			_ = try await persistHistoryEntry(
          text: result,
          audioURL: audioURL,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          status: .completed,
		  transcriptionHistory: transcriptionHistory,
			  screenshotData: screenshotData,
			  rawText: rawTranscript ?? originalTranscript ?? result,
			  selectedText: selectedText?.text,
			  screenshotRecognizedText: screenshotRecognizedText,
			  processingErrors: processingErrors,
			  wasRefined: wasRefined,
			  outputGenerationDuration: outputGenerationDuration,
			  screenAwareInputSource: screenAwareInputSource
			)
      } catch {
        // Storage failure on the success path: log, clean up the temp file (still at original
        // location since save threw before move-item completed), but DO NOT mark as failed —
        // the transcription itself succeeded and the user should still get their text.
        transcriptionFeatureLogger.error(
          "Failed to persist completed transcript: \(error.localizedDescription, privacy: .private)"
        )
        try? FileManager.default.removeItem(at: audioURL)
      }
    } else {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

	if selectedText == nil {
		await pasteboard.paste(result)
		soundEffect.play(.pasteTranscript)
		return
	}

	switch selectionReplacementResult {
	case .replaced:
		soundEffect.play(.pasteTranscript)
	case .clipboardChanged:
		transcriptionFeatureLogger.notice("Skipped selected-text replacement because the source app or clipboard changed")
	case .pasteFailed:
		transcriptionFeatureLogger.warning("Selected-text replacement failed after refinement")
	case nil:
		break
	}
  }

  /// Persist an entry in history (move audio + insert + prune to maxHistoryEntries).
  /// Returns nil if `saveTranscriptionHistory` is disabled (caller is responsible for cleanup).
  /// Throws on storage failure.
  func persistHistoryEntry(
    text: String,
    audioURL: URL,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    status: TranscriptStatus,
	transcriptionHistory: Shared<TranscriptionHistory>,
	screenshotData: Data? = nil,
	rawText: String? = nil,
	selectedText: String? = nil,
		screenshotRecognizedText: String? = nil,
		processingErrors: [TranscriptProcessingError]? = nil,
		wasRefined: Bool? = nil,
		outputGenerationDuration: TimeInterval? = nil,
		screenAwareInputSource: ScreenAwareInputSource? = nil
  ) async throws -> Transcript? {
    @Shared(.hexSettings) var hexSettings: HexSettings

    guard hexSettings.saveTranscriptionHistory else { return nil }

    let transcript = try await transcriptPersistence.save(.init(
		text: text,
		audioURL: audioURL,
		duration: duration,
		sourceAppBundleID: sourceAppBundleID,
		sourceAppName: sourceAppName,
		status: status,
		screenshotData: screenshotData,
		rawText: rawText,
		selectedText: selectedText,
			screenshotRecognizedText: screenshotRecognizedText,
			processingErrors: processingErrors,
			wasRefined: wasRefined,
			outputGenerationDuration: outputGenerationDuration,
			screenAwareInputSource: screenAwareInputSource
	))

		await insertHistoryEntry(transcript, at: 0, transcriptionHistory: transcriptionHistory)
    return transcript
  }

	func insertHistoryEntry(_ transcript: Transcript, at index: Int, transcriptionHistory: Shared<TranscriptionHistory>) async {
		@Shared(.hexSettings) var hexSettings: HexSettings
		var audioToDelete: [Transcript] = []
		transcriptionHistory.withLock { history in
			history.history.insert(transcript, at: min(index, history.history.count))
			guard let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 else { return }
			while history.history.count > maxEntries, let removedTranscript = history.history.popLast() {
				if !history.history.contains(where: { $0.audioPath == removedTranscript.audioPath }) {
					audioToDelete.append(removedTranscript)
				}
			}
		}
		for transcript in audioToDelete {
			try? await transcriptPersistence.deleteArtifacts(transcript)
		}
	}

  /// Persist an incomplete recording (cancelled or failed) when duration meets the 1.0s
  /// threshold and history is enabled; otherwise delete the temp WAV. Storage failures
  /// fall back to deleting the temp file so we don't leak.
  func persistOrDiscard(
    status: TranscriptStatus,
    audioURL: URL,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
	transcriptionHistory: Shared<TranscriptionHistory>,
	screenshotData: Data? = nil,
	text: String = "",
	rawText: String? = nil,
	selectedText: String? = nil,
		screenshotRecognizedText: String? = nil,
		processingErrors: [TranscriptProcessingError]? = nil,
		wasRefined: Bool? = nil,
		outputGenerationDuration: TimeInterval? = nil
  ) async {
    @Shared(.hexSettings) var hexSettings: HexSettings

    // Floor at the user's minimumKeyTime so high-threshold users don't see sub-threshold
    // recordings persisted, with 1.0s as an absolute lower bound to keep storage bounded
    // against rapid modifier taps from users with very low minimumKeyTime values.
    let meetsMinimumDuration = duration >= max(hexSettings.minimumKeyTime, 1.0)
    let shouldPersist = meetsMinimumDuration
      && hexSettings.saveTranscriptionHistory

    guard shouldPersist else {
      try? FileManager.default.removeItem(at: audioURL)
      return
    }

    do {
      _ = try await persistHistoryEntry(
		text: text,
        audioURL: audioURL,
        duration: duration,
        sourceAppBundleID: sourceAppBundleID,
        sourceAppName: sourceAppName,
        status: status,
		transcriptionHistory: transcriptionHistory,
		screenshotData: screenshotData,
		rawText: rawText,
		selectedText: selectedText,
			screenshotRecognizedText: screenshotRecognizedText,
			processingErrors: processingErrors,
			wasRefined: wasRefined,
			outputGenerationDuration: outputGenerationDuration
      )
    } catch {
      transcriptionFeatureLogger.error(
        "Failed to persist incomplete transcript (\(String(describing: status))): \(error.localizedDescription, privacy: .private)"
      )
      try? FileManager.default.removeItem(at: audioURL)
    }
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
	func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
	let wasRefining = state.isRefining
	state.isTranscribing = false
	state.isRefining = false
		state.outputGenerationStartTime = nil
		deactivateScreenAwareMode(&state)
		state.isCapturingSelectedTextForRefinement = false
		state.refinedHotKeyReleasedWhileCapturingSelection = false
			let selectedText = state.selectedTextForRefinement
			state.selectedTextForRefinement = nil
			// A cancellation during AI processing must keep the local transcript. It
			// has already completed and is independently useful for replay or retry.
			let originalTranscript = state.originalTranscriptForRefinement
			state.originalTranscriptForRefinement = nil
			let screenContext = state.screenContextForRefinement
			let screenshotData = screenContext?.imagePNGData
			let stagedScreenshotPath = state.stagedScreenContextScreenshotPath
			state.stagedScreenContextScreenshotPath = nil
			state.screenContextForRefinement = nil
			state.screenContextCaptureID = nil
			state.screenContextCaptureErrorMessage = nil
			state.pendingScreenAwareTranscription = nil
    state.isRecording = false
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
    state.isPrewarming = false

    // Snapshot any captured transcription metadata before clearing — handleCancel during
    // transcription owns the audio file because the in-flight transcribe effect is being killed.
    let activeURL = state.activeTranscriptionAudioURL
    let activeDuration = state.activeTranscriptionDuration
			let historyCheckpointID = state.activeHistoryTranscriptID
	state.activeHistoryTranscriptID = nil
    state.activeTranscriptionAudioURL = nil
    state.activeTranscriptionDuration = nil

    // Capture the cancel time at action-processing time so the duration reflects
    // when the user pressed cancel, not when the .run block actually executes.
    // Also keeps the timing path test-injectable via @Dependency(\.date.now).
    let cancelTime = now
    let recordingStartTime = state.recordingStartTime
    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .merge(
      .cancel(id: CancelID.transcription),
				.cancel(id: CancelID.selectedTextRefinement),
				.cancel(id: CancelID.screenContextCapture),
				.cancel(id: CancelID.screenAwareActivation),
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
		await selectedText?.cancel()
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        soundEffect.play(.cancel)

		if let activeURL {
			if let historyCheckpointID {
				transcriptionHistory.withLock { history in
					guard let index = history.history.firstIndex(where: { $0.id == historyCheckpointID }) else { return }
					var checkpoint = history.history[index]
					checkpoint.text = originalTranscript ?? checkpoint.text
					checkpoint.rawText = originalTranscript ?? checkpoint.rawText
					checkpoint.selectedText = selectedText?.text ?? checkpoint.selectedText
					checkpoint.screenshotRecognizedText = screenContext?.recognizedText ?? checkpoint.screenshotRecognizedText
					checkpoint.wasRefined = wasRefining
					checkpoint.status = .cancelled
					history.history[index] = checkpoint
				}
			} else {
				await persistOrDiscard(
					status: .cancelled,
					audioURL: activeURL,
					duration: activeDuration ?? 0,
					sourceAppBundleID: sourceAppBundleID,
					sourceAppName: sourceAppName,
					transcriptionHistory: transcriptionHistory,
					screenshotData: screenshotData,
					text: originalTranscript ?? "",
					rawText: originalTranscript,
					selectedText: selectedText?.text,
					screenshotRecognizedText: screenContext?.recognizedText,
					wasRefined: wasRefining
				)
			}
			} else if wasRecording {
          // Cancel during recording — stop recording to get the temp URL.
          let stopResult = await recording.stopRecording()
          guard !Task.isCancelled else { return }
          guard case let .captured(url) = stopResult else { return }
          let duration = recordingStartTime.map { cancelTime.timeIntervalSince($0) } ?? 0
          await persistOrDiscard(
            status: .cancelled,
            audioURL: url,
            duration: duration,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
			transcriptionHistory: transcriptionHistory,
			screenshotData: screenshotData
          )
			}
			if historyCheckpointID == nil, let stagedScreenshotPath {
				try? FileManager.default.removeItem(at: stagedScreenshotPath)
			}
      }
      .cancellable(id: CancelID.recordingFinalize)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
	state.isRecording = false
	deactivateScreenAwareMode(&state)
		state.outputGenerationStartTime = nil
    state.isPrewarming = false
	state.forcedRefinementMode = nil
	state.activeRecordingHotkey = nil
	state.activeMinimumKeyTime = nil
	state.activeRecordingSource = nil
			let selectedText = state.selectedTextForRefinement
			state.selectedTextForRefinement = nil
			state.originalTranscriptForRefinement = nil
			state.screenContextForRefinement = nil
			state.screenContextCaptureID = nil
			state.screenContextCaptureErrorMessage = nil
			state.pendingScreenAwareTranscription = nil

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
			.cancel(id: CancelID.screenContextCapture),
			.cancel(id: CancelID.screenAwareActivation),
      .run { [sleepManagement] _ in
		await selectedText?.cancel()
        // Allow system to sleep again
        await sleepManagement.allowSleep()
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
		guard !Task.isCancelled else { return }
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
	if store.isScreenAwareModeActive {
	  return .screenAware
	} else if store.isRefining {
	  return .refining
	} else if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
	let indicatorStatus = status
    TranscriptionIndicatorView(
	  status: indicatorStatus,
	  meter: indicatorStatus == .recording ? store.meter : .init(averagePower: 0, peakPower: 0)
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
