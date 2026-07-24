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
		max(settings.minimumKeyTime, minimumHoldDuration)
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
			case .codexCLI, .claudeCLI:
				return true
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
		case .apple, .gemini, .codexCLI, .claudeCLI:
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

	/// A completed local transcription that is waiting for the parallel selected-text
	/// lookup. Keeping it in the reducer avoids pasting raw text before a detected
	/// selection can force the downstream refinement step.
	struct PendingSelectedTextTranscription: Equatable {
		let text: String
		let audioURL: URL
	}

  @ObservableState
	struct State: Equatable {
		struct RecentCompletedTranscript: Equatable {
			let id: UUID
			let text: String
			let historyID: UUID?
		}

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
			var screenContextCaptureID: UUID?
			var screenContextCaptureErrorMessage: String?
			var pendingScreenAwareTranscription: PendingScreenAwareTranscription?
			var pendingSelectedTextTranscription: PendingSelectedTextTranscription?
    var isPrewarming: Bool = false
		var forcedRefinementMode: RefinementMode?
		/// The most recent ordinary result remains eligible for the quick
		/// post-hold refinement gesture even after it has been pasted.
		var recentCompletedTranscript: RecentCompletedTranscript?
		var postHocRefinement: RecentCompletedTranscript?
		var pendingPressAndHoldActivationID: UUID?
		var pendingTerminalRefinementID: UUID?
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
		case armPendingPressAndHold
		case pendingPressAndHoldActivated(UUID)
		case cancelPendingPressAndHold
		case armTerminalRefinement
		case terminalRefinementActivated(UUID)
		case armScreenAwareActivation
		case screenAwareActivationThresholdReached
		case cancelScreenAwareActivation
    case hotKeyPressed
    case hotKeyReleased(RecordingSource)
			case refinedHotKeyPressed
			case screenAwareModeActivated
				case finishRecordingWithRefinement
				case refineMostRecentTranscription
				case recentTranscriptRefined(UUID, String)
				case recentTranscriptRefinementFailed(UUID, String)
				case startSelectedTextOnlyRefinement
				case selectedTextOnlyRefinementResult(String)
				case selectedTextOnlyRefinementFailed(String)
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
	case showError(String)
	case dismissError

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
		case postHocRefinement
		case selectedTextOnlyRefinement
		case selectedTextRefinement
		case errorPresentation
		case pendingPressAndHold
		case terminalRefinementHold
		case screenAwareActivation
			case screenContextCapture
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

		case .armPendingPressAndHold:
			guard !state.isRecording, !state.isTranscribing, !state.isRefining else { return .none }
			let activationID = uuid()
			state.pendingPressAndHoldActivationID = activationID
			return .run { [clock] send in
				try await clock.sleep(for: .seconds(HotKeyProcessor.doubleTapThreshold))
				await send(.pendingPressAndHoldActivated(activationID))
			}
			.cancellable(id: CancelID.pendingPressAndHold, cancelInFlight: true)

		case let .pendingPressAndHoldActivated(activationID):
			guard state.pendingPressAndHoldActivationID == activationID else { return .none }
			state.pendingPressAndHoldActivationID = nil
			return .send(.hotKeyPressed)

		case .cancelPendingPressAndHold:
			state.pendingPressAndHoldActivationID = nil
			return .cancel(id: CancelID.pendingPressAndHold)

		case .armTerminalRefinement:
			guard state.isRecording, state.activeRecordingSource == .regular else { return .none }
			let activationID = uuid()
			let holdDuration = ScreenAwareActivation.holdDuration(for: state.hexSettings)
			state.pendingTerminalRefinementID = activationID
			return .run { [clock] send in
				try await clock.sleep(for: .seconds(holdDuration))
				await send(.terminalRefinementActivated(activationID))
			}
			.cancellable(id: CancelID.terminalRefinementHold, cancelInFlight: true)

		case let .terminalRefinementActivated(activationID):
			guard state.pendingTerminalRefinementID == activationID,
				state.isRecording,
				state.activeRecordingSource == .regular
			else { return .none }
			state.pendingTerminalRefinementID = nil
			return .send(.finishRecordingWithRefinement)

		case .armScreenAwareActivation:
			guard state.isRecording, state.activeRecordingSource == .regular else { return .none }
			let holdDuration = ScreenAwareActivation.holdDuration(for: state.hexSettings)
			return .run { [clock] send in
				try await clock.sleep(for: .seconds(holdDuration))
				await send(.screenAwareActivationThresholdReached)
			}
			.cancellable(id: CancelID.screenAwareActivation, cancelInFlight: true)

		case .screenAwareActivationThresholdReached:
			guard state.isRecording,
				state.activeRecordingSource == .regular,
				!state.isScreenAwareModeActive
			else { return .none }
			return .send(.screenAwareModeActivated)

		case .cancelScreenAwareActivation:
			return .cancel(id: CancelID.screenAwareActivation)

      case .hotKeyPressed:
		state.pendingPressAndHoldActivationID = nil
		// Start recording immediately. Selection detection is deliberately parallel:
		// a missing selection must never delay dictation or trigger a synthetic Copy
		// command's system error sound.
		if !state.isRecording,
			!state.isTranscribing,
			!state.isRefining,
			state.hexSettings.includeSelectedTextInRefinement
		{
			let startRecording = handleStartRecording(&state, source: .regular)
			return .merge(
				.cancel(id: CancelID.pendingPressAndHold),
				startRecording,
				.send(.refinedHotKeyPressed)
			)
		}
		return .merge(
			.cancel(id: CancelID.pendingPressAndHold),
			handleHotKeyPressed(isBusy: state.isTranscribing || state.isRefining)
		)

	case .hotKeyReleased(.regular):
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
		state.pendingPressAndHoldActivationID = nil
		state.pendingTerminalRefinementID = nil
		if state.isScreenAwareModeActive {
			return .merge(
				.cancel(id: CancelID.pendingPressAndHold),
				.cancel(id: CancelID.terminalRefinementHold),
				.cancel(id: CancelID.screenAwareActivation),
				.send(.finishScreenAwareRecording)
			)
		}
		return .merge(
			.cancel(id: CancelID.pendingPressAndHold),
			.cancel(id: CancelID.terminalRefinementHold),
			.cancel(id: CancelID.screenAwareActivation),
			handleHotKeyReleased(isRecording: state.isRecording, source: .regular, activeSource: state.activeRecordingSource)
		)

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
					return .none
				}
				return handleHotKeyReleased(
					isRecording: state.isRecording,
					source: .refined,
					activeSource: state.activeRecordingSource
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

			case .screenAwareModeActivated:
					guard state.isRecording,
						state.activeRecordingSource == .regular,
						!state.isScreenAwareModeActive
					else { return .none }
					let cancelScreenAwareActivation = Effect<Action>.cancel(id: CancelID.screenAwareActivation)
					state.forcedRefinementMode = .refined
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
					return .merge(cancelScreenAwareActivation, captureScreen)

				case .finishRecordingWithRefinement:
				// A held terminal activation selects refinement while the regular hotkey
				// still owns the recording. Preserve the original session's timing rules.
				guard state.isRecording, state.activeRecordingSource == .regular else { return .none }
					state.pendingTerminalRefinementID = nil
					state.forcedRefinementMode = .refined
					return .merge(
						.cancel(id: CancelID.terminalRefinementHold),
						.send(.stopRecording)
					)

				case .refineMostRecentTranscription:
					// If decoding is still underway, mark that active session for refinement.
					// Otherwise refine the just-completed, already-pasted result retained below.
					if state.isTranscribing {
						state.forcedRefinementMode = .refined
						return .none
					}
					guard !state.isRecording,
						!state.isRefining,
						let transcript = state.recentCompletedTranscript
					else { return .none }
					state.postHocRefinement = transcript
					state.isRefining = true
					state.outputGenerationStartTime = now
					let request = state.hexSettings.refinementRequest(
						for: transcript.text,
						mode: .refined
					)
					return .run { [refinement] send in
						do {
							let refinedResult = try await refinement.refine(request)
							try Task.checkCancellation()
							await send(.recentTranscriptRefined(transcript.id, refinedResult))
						} catch is CancellationError {
							return
						} catch {
							transcriptionFeatureLogger.warning("Post-hoc refinement failed: \(error.localizedDescription, privacy: .private)")
							await send(.recentTranscriptRefinementFailed(transcript.id, error.localizedDescription))
						}
					}
					.cancellable(id: CancelID.postHocRefinement, cancelInFlight: true)

				case let .recentTranscriptRefined(id, result):
					guard let transcript = state.postHocRefinement, transcript.id == id else { return .none }
					state.postHocRefinement = nil
					state.isRefining = false
					state.outputGenerationStartTime = nil
					state.recentCompletedTranscript = .init(
						id: UUID(),
						text: result,
						historyID: transcript.historyID
					)
					let transcriptionHistory = state.$transcriptionHistory
					return .run { [pasteboard] _ in
						if let historyID = transcript.historyID {
							transcriptionHistory.withLock { history in
								guard let index = history.history.firstIndex(where: { $0.id == historyID }) else { return }
								var entry = history.history[index]
								entry.text = result
								entry.rawText = transcript.text
								entry.wasRefined = true
								history.history[index] = entry
							}
						}
						await pasteboard.paste(result)
						soundEffect.play(.pasteTranscript)
					}
					.cancellable(id: CancelID.postHocRefinement, cancelInFlight: true)

				case let .recentTranscriptRefinementFailed(id, message):
					guard state.postHocRefinement?.id == id else { return .none }
					state.postHocRefinement = nil
					state.isRefining = false
					state.outputGenerationStartTime = nil
					return .send(.showError(message))

				case .finishScreenAwareRecording:
					if state.isCapturingSelectedTextForRefinement {
						deactivateScreenAwareMode(&state)
						state.refinedHotKeyReleasedWhileCapturingSelection = true
						return .none
					}
					// Screen-aware mode can either start its own recording or upgrade an
					// already-running regular session. In both cases the unified hotkey owns
					// the active recording and must be able to finish it.
					guard state.isRecording else {
						deactivateScreenAwareMode(&state)
						return .none
					}
					deactivateScreenAwareMode(&state)
					return .send(.stopRecording)

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
				state.isCapturingSelectedTextForRefinement = false
				state.refinedHotKeyReleasedWhileCapturingSelection = false
				guard let pending = state.pendingSelectedTextTranscription else { return .none }
				state.pendingSelectedTextTranscription = nil
				return .send(.transcriptionResult(pending.text, pending.audioURL))

			case let .selectedTextCaptured(selectedText):
				state.isCapturingSelectedTextForRefinement = false
				state.refinedHotKeyReleasedWhileCapturingSelection = false
				state.selectedTextForRefinement = selectedText
				if state.isRecording || state.isTranscribing {
					state.forcedRefinementMode = .refined
					if let pending = state.pendingSelectedTextTranscription {
						state.pendingSelectedTextTranscription = nil
						return .send(.transcriptionResult(pending.text, pending.audioURL))
					}
					return .none
				}
				return .send(.startSelectedTextOnlyRefinement)

			case .startSelectedTextOnlyRefinement:
				guard let selectedText = state.selectedTextForRefinement else { return .none }
				state.isRefining = true
				state.outputGenerationStartTime = now
				let request = state.hexSettings.refinementRequest(
					for: selectedText.text,
					mode: .refined
				)
				return .run { [refinement] send in
					do {
						let refinedResult = try await refinement.refine(request)
						try Task.checkCancellation()
						await send(.selectedTextOnlyRefinementResult(refinedResult))
					} catch is CancellationError {
						return
					} catch {
						await send(.selectedTextOnlyRefinementFailed(error.localizedDescription))
					}
				}
				.cancellable(id: CancelID.selectedTextOnlyRefinement, cancelInFlight: true)

			case let .selectedTextOnlyRefinementResult(result):
				guard state.selectedTextForRefinement != nil else { return .none }
				state.selectedTextForRefinement = nil
				state.isRefining = false
				state.outputGenerationStartTime = nil
				return .run { [pasteboard] _ in
					await pasteboard.paste(result)
					soundEffect.play(.pasteTranscript)
				}

			case let .selectedTextOnlyRefinementFailed(message):
				state.isRefining = false
				state.outputGenerationStartTime = nil
				state.error = message
				let selectedText = state.selectedTextForRefinement
				state.selectedTextForRefinement = nil
				return .merge(
					.run { _ in await selectedText?.cancel() },
					.send(.showError(message))
				)

      // MARK: - Recording Flow

      case .startRecording:
		return handleStartRecording(&state, source: .regular)

		case .startRefinedRecording:
			return handleStartRecording(&state, forcedRefinementMode: .refined, source: .regular)

      case .stopRecording:
		state.pendingTerminalRefinementID = nil
		return .merge(
			.cancel(id: CancelID.terminalRefinementHold),
			.cancel(id: CancelID.screenAwareActivation),
			handleStopRecording(&state)
		)

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
					while history.history.count > maximumEntries,
						  let index = history.history.lastIndex(where: { $0.recoverySessionID == nil }) {
						let removedTranscript = history.history.remove(at: index)
						if !history.history.contains(where: { $0.audioPath == removedTranscript.audioPath }) {
							artifactsToDelete.append(removedTranscript)
						}
					}
				}
				return artifactsToDelete
			}
			return .run { [recording] _ in
				for transcript in artifactsToDelete {
					try? await transcriptPersistence.deleteArtifacts(transcript)
				}
				await recording.releaseRecordingSource(transcript.audioPath)
			}

      case let .transcriptionResult(result, audioURL):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL)

	  case let .refinementResult(result, audioURL, duration):
		return handleRefinementResult(&state, result: result, audioURL: audioURL, duration: duration)

      case let .transcriptionError(error, audioURL):
			guard state.activeTranscriptionAudioURL == audioURL else { return .none }
			return .merge(
				handleTranscriptionError(&state, error: error, audioURL: audioURL),
				.run { send in
					try? await clock.sleep(for: .seconds(5))
					guard !Task.isCancelled else { return }
					await send(.dismissError)
				}
				.cancellable(id: CancelID.errorPresentation, cancelInFlight: true)
			)

		case let .showError(message):
			state.error = message
			return .run { send in
				try? await clock.sleep(for: .seconds(5))
				guard !Task.isCancelled else { return }
				await send(.dismissError)
			}
			.cancellable(id: CancelID.errorPresentation, cancelInFlight: true)

		case .dismissError:
			state.error = nil
			return .cancel(id: CancelID.errorPresentation)

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
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
			if isSettingHotKey {
	          return false
	        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
	        let supportsScreenAwareGesture = ScreenAwareActivation.isAvailable(with: hexSettings)
	        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled
	          && hexSettings.useDoubleTapOnly
	        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
	        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
	        hotKeyProcessor.allowLongPressForOnDemand = hexSettings.allowLongPressForOnDemand
	        hotKeyProcessor.lockingHoldDuration = max(
	          hexSettings.minimumKeyTime,
	          ScreenAwareActivation.minimumHoldDuration
	        )
	        hotKeyProcessor.screenAwareSecondTapEnabled = supportsScreenAwareGesture
	        hotKeyProcessor.postHoldRefinementEnabled = !hexSettings.doubleTapLockEnabled
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
		  // The screen-area overlay owns Escape while a region is being drawn.
		  // Let its local monitor reset/cancel the rectangle without the global
		  // hotkey processor cancelling the active recording.
		  if keyEvent.key == .escape, ScreenCaptureSelectionOverlay.isSelectingRegion {
			return false
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
		  case .armPendingPressAndHold:
			Task { await send(.armPendingPressAndHold) }
			return useDoubleTapOnly || keyEvent.key != nil

		  case .cancelPendingPressAndHold:
			Task { await send(.cancelPendingPressAndHold) }
			return false

		  case .armTerminalRefinement:
			Task { await send(.armTerminalRefinement) }
			return useDoubleTapOnly || keyEvent.key != nil

		  case .startRecording:
			Task { await send(.hotKeyPressed) }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
			return useDoubleTapOnly || keyEvent.key != nil

		  case .startRecordingAndArmScreenAware:
			Task {
				await send(.hotKeyPressed)
				await send(.armScreenAwareActivation)
			}
			return useDoubleTapOnly || keyEvent.key != nil

		  case .stopRecording:
			Task { await send(.hotKeyReleased(.regular)) }
            return false // or `true` if you want to intercept

		  case .locked:
			if hotKeyProcessor.isLongPressLocked, supportsScreenAwareGesture {
				Task { await send(.screenAwareModeActivated) }
			} else {
				Task { await send(.cancelScreenAwareActivation) }
			}
			return false

		  case .stopRecordingWithRefinement:
			Task { await send(.finishRecordingWithRefinement) }
			return false

		  case .stopRecordingWithScreenContext:
			Task {
				await send(.screenAwareModeActivated)
				await send(.stopRecording)
			}
			return false

		  case .refineMostRecentTranscription:
			Task { await send(.refineMostRecentTranscription) }
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
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
		  case .cancel:
			Task { await send(.hotKeyCancelled(.regular)) }
            return false // Don't intercept the click itself
		  case .discard:
			Task { await send(.hotKeyDiscarded(.regular)) }
            return false // Don't intercept the click itself
		  case .armPendingPressAndHold, .cancelPendingPressAndHold, .armTerminalRefinement,
				 .startRecording, .startRecordingAndArmScreenAware, .stopRecording, .stopRecordingWithRefinement,
				 .stopRecordingWithScreenContext, .refineMostRecentTranscription, .locked, .none:
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
			state.pendingSelectedTextTranscription = nil
			state.pendingPressAndHoldActivationID = nil
			state.pendingTerminalRefinementID = nil
		state.forcedRefinementMode = forcedRefinementMode
	state.activeRecordingHotkey = state.hexSettings.hotkey
	state.activeMinimumKeyTime = state.hexSettings.minimumKeyTime
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
			.cancel(id: CancelID.terminalRefinementHold),
			.cancel(id: CancelID.screenAwareActivation),
			cancelsScreenContextCapture ? .cancel(id: CancelID.screenContextCapture) : .none,
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Octo Voice Recording")
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

	// The gesture itself can be meaningful without a long audio capture. Do not
	// discard screen-aware or selected-text refinement merely because the recorded
	// audio duration is shorter than the normal transcription threshold.
	let screenAwareCaptureInFlight = state.screenContextCaptureID != nil
	let selectedTextRefinementRequested = state.selectedTextForRefinement != nil
		|| state.isCapturingSelectedTextForRefinement
    guard decision == .proceedToTranscription
		|| screenAwareCaptureInFlight
		|| selectedTextRefinementRequested
	else {
		let selectedText = state.selectedTextForRefinement
			state.selectedTextForRefinement = nil
			state.screenContextForRefinement = nil
			state.screenContextCaptureID = nil
			state.pendingScreenAwareTranscription = nil
			state.pendingSelectedTextTranscription = nil
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
            RecordingRecoveryStore.releaseSource(forFinalAudioURL: unownedAudioURL)
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
    state.pendingSelectedTextTranscription = nil
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
      .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
        RecordingRecoveryStore.releaseSource(forFinalAudioURL: audioURL)
      }
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

    // Selection lookup starts in parallel with recording. If transcription wins that
    // race, keep its result intact until the lookup can either force refinement or
    // confirm that there was no selection.
    if state.isCapturingSelectedTextForRefinement {
      state.pendingSelectedTextTranscription = .init(text: result, audioURL: audioURL)
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
		  state.pendingSelectedTextTranscription = nil
	  state.forcedRefinementMode = nil
	  state.activeRecordingHotkey = nil
	  state.activeMinimumKeyTime = nil
	  state.activeRecordingSource = nil
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Octo.")
	      return .merge(
			.cancel(id: CancelID.screenContextCapture),
			.run { _ in
				FileManager.default.removeItemIfExists(at: audioURL)
				RecordingRecoveryStore.releaseSource(forFinalAudioURL: audioURL)
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

		// Refinement is selected by the terminal hold, selected text, or the
		// screen-aware start gesture; the configured start hotkey stays unified.
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
		state.recentCompletedTranscript = .init(
			id: UUID(),
			text: modifiedResult,
			historyID: historyCheckpointID
		)
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
				@Shared(.hexSettings) var settings: HexSettings
				if settings.refinementReasoningEffort != request.reasoningEffort {
					await send(.showError("Thinking level not supported. Changed to \(settings.refinementReasoningEffort.displayName)."))
				}
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
	deactivateScreenAwareMode(&state)
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
			state.pendingSelectedTextTranscription = nil
		state.forcedRefinementMode = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil

	let sourceAppBundleID = state.sourceAppBundleID
	let sourceAppName = state.sourceAppName
	let transcriptionHistory = state.$transcriptionHistory
	let historyCheckpointID = state.activeHistoryTranscriptID
	state.recentCompletedTranscript = .init(
		id: UUID(),
		text: result,
		historyID: historyCheckpointID
	)
	// Selected text is context for the refinement request, never transcription.
	// In the silent selected-text path, retain an explicit empty raw transcript so
	// History shows the generated replacement as a result rather than mislabeling
	// it (or the selection) as spoken text.
	let rawTranscriptForHistory = selectedText == nil
		? (originalTranscript ?? result)
		: (originalTranscript ?? "")
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
			rawTranscript: rawTranscriptForHistory,
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
			state.pendingSelectedTextTranscription = nil
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
        RecordingRecoveryStore.releaseSource(forFinalAudioURL: audioURL)
      }
    } else {
      FileManager.default.removeItemIfExists(at: audioURL)
      RecordingRecoveryStore.releaseSource(forFinalAudioURL: audioURL)
    }

	// Selected text is refinement context only. Always paste the generated output
	// at the insertion point that is active when processing completes.
	await pasteboard.paste(result)
	soundEffect.play(.pasteTranscript)
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
    await recording.releaseRecordingSource(transcript.audioPath)
    return transcript
  }

	func insertHistoryEntry(_ transcript: Transcript, at index: Int, transcriptionHistory: Shared<TranscriptionHistory>) async {
		@Shared(.hexSettings) var hexSettings: HexSettings
		var audioToDelete: [Transcript] = []
		transcriptionHistory.withLock { history in
			history.history.insert(transcript, at: min(index, history.history.count))
			guard let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 else { return }
			while history.history.count > maxEntries,
				  let index = history.history.lastIndex(where: { $0.recoverySessionID == nil }) {
				let removedTranscript = history.history.remove(at: index)
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
      RecordingRecoveryStore.releaseSource(forFinalAudioURL: audioURL)
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
      RecordingRecoveryStore.releaseSource(forFinalAudioURL: audioURL)
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
	state.pendingPressAndHoldActivationID = nil
	state.pendingTerminalRefinementID = nil
	state.pendingScreenAwareTranscription = nil
		state.postHocRefinement = nil
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
			state.pendingSelectedTextTranscription = nil
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
				.cancel(id: CancelID.pendingPressAndHold),
				.cancel(id: CancelID.terminalRefinementHold),
				.cancel(id: CancelID.postHocRefinement),
				.cancel(id: CancelID.selectedTextOnlyRefinement),
				.cancel(id: CancelID.selectedTextRefinement),
				.cancel(id: CancelID.screenContextCapture),
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
	state.pendingPressAndHoldActivationID = nil
	state.pendingTerminalRefinementID = nil
		state.postHocRefinement = nil
		state.outputGenerationStartTime = nil
    state.isPrewarming = false
	state.isCapturingSelectedTextForRefinement = false
	state.refinedHotKeyReleasedWhileCapturingSelection = false
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
			state.pendingSelectedTextTranscription = nil

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
			.cancel(id: CancelID.pendingPressAndHold),
			.cancel(id: CancelID.terminalRefinementHold),
			.cancel(id: CancelID.screenAwareActivation),
			.cancel(id: CancelID.postHocRefinement),
			.cancel(id: CancelID.selectedTextRefinement),
			.cancel(id: CancelID.screenContextCapture),
      .run { [sleepManagement] _ in
		await selectedText?.cancel()
        // Allow system to sleep again
        await sleepManagement.allowSleep()
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		  RecordingRecoveryStore.releaseSource(forFinalAudioURL: url)
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
  @Shared(.hexSettings) var hexSettings: HexSettings

  var status: TranscriptionIndicatorView.Status {
	if let error = store.error {
		return .error(error)
	} else if store.isScreenAwareModeActive {
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
		  meter: indicatorStatus == .recording ? store.meter : .init(averagePower: 0, peakPower: 0),
		  size: hexSettings.indicatorSize
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
