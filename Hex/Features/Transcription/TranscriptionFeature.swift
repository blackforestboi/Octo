//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import Carbon
import CoreGraphics
import Foundation
import HexCore
import Inject
import Sauce
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

/// Tracks a held number while the global event tap decides whether it is ordinary
/// input or a rewrite-prompt shortcut. Access is synchronized because the timer
/// task and the event-tap callback can complete at nearly the same instant.
private final class RewritePromptHold: @unchecked Sendable {
	let key: Key
	private let lock = NSLock()
	private var didTrigger = false

	init(key: Key) {
		self.key = key
	}

	func markTriggered() {
		lock.lock()
		didTrigger = true
		lock.unlock()
	}

	func hasTriggered() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return didTrigger
	}
}

private final class RewritePromptHoldTracker: @unchecked Sendable {
	private let lock = NSLock()
	private var active: (hold: RewritePromptHold, task: Task<Void, Never>)?

	func hasTriggered() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return active?.hold.hasTriggered() == true
	}

	func matches(_ key: Key) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		return active?.hold.key == key
	}

	func replace(with hold: RewritePromptHold, task: Task<Void, Never>) {
		lock.lock()
		let previous = active
		active = (hold, task)
		lock.unlock()
		previous?.task.cancel()
	}

	func take(for key: Key?) -> (hold: RewritePromptHold, task: Task<Void, Never>)? {
		lock.lock()
		defer { lock.unlock() }
		guard let key, let active, active.hold.key == key else { return nil }
		self.active = nil
		return active
	}
}

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

private func rewritePromptNumber(for key: Key?) -> Int? {
	guard let key else { return nil }
	switch key {
	case .one: return 1
	case .two: return 2
	case .three: return 3
	case .four: return 4
	case .five: return 5
	case .six: return 6
	case .seven: return 7
	case .eight: return 8
	case .nine: return 9
	default: return nil
	}
}

/// A Shift-modified terminal hotkey routes the active ordinary recording to Agent Handoff.
/// A configured hotkey that already includes Shift has no unambiguous handoff ending gesture.
private enum AgentHandoffEndingGesture {
	case none
	case consume
	case finish
}

private extension KeyEvent {
	var isShiftModifierTransition: Bool {
		phase == .other
			&& (virtualKeyCode == kVK_Shift || virtualKeyCode == kVK_RightShift)
	}
}

private func agentHandoffEndingGesture(
	for event: KeyEvent,
	hotkey: HotKey,
	processorState: HotKeyProcessor.State
) -> AgentHandoffEndingGesture {
	guard !hotkey.modifiers.contains(.shift) else { return .none }
	// Shift itself must remain an ordinary modifier for the focused app while a
	// recording is active. In particular, it cannot finish Agent Handoff just by
	// going down. The ending hotkey selects Agent Handoff when it is released or
	// pressed with Shift already held.
	guard !event.isShiftModifierTransition else { return .none }

	let shiftedModifiers = hotkey.modifiers.union([.shift])
	switch processorState {
	case .pressAndHold:
		if hotkey.key != nil {
			return event.isKeyUp && event.modifiers.matchesExactly(shiftedModifiers)
				? .finish
				: .none
		}
		// For a modifier-only hotkey, choosing Agent Handoff happens when the
		// final configured modifier is released while Shift remains held.
		return event.phase == .other && event.modifiers.matchesExactly([.shift])
			? .finish
			: .none

	case .doubleTapLock, .endingHold:
		// A locked recording may receive Shift before the configured hotkey. Keep
		// those in-progress chord events out of the ordinary processor so they do
		// not mark it dirty before the terminating hotkey arrives.
		guard event.modifiers.contains(.shift), event.modifiers.isSubset(of: shiftedModifiers) else {
			return .none
		}
		guard event.modifiers.matchesExactly(shiftedModifiers) else { return .consume }
		return hotkey.key == nil || (event.isKeyDown && event.key == hotkey.key)
			? .finish
			: .consume

	case .idle, .pendingPressAndHold:
		return .none
	}
}

@Reducer
struct TranscriptionFeature {
  enum RecordingSource: Equatable {
    case regular
    case refined
  }

	enum CompletedTranscriptPresentation: Equatable {
		case expanded(String)
		case copied(String)
		case hidingCopied(String)
	}

	struct PendingScreenAwareTranscription: Equatable {
		let text: String
		let audioURL: URL
		let duration: TimeInterval
	}

	struct TranscribedAudioChannel: Equatable, Sendable {
		let source: TranscriptAudioSource
		let audioURL: URL
		let duration: TimeInterval
		let startOffset: TimeInterval
		let output: TranscriptionOutput
	}

	struct ProcessedAudioChannel: Equatable {
		let source: TranscriptAudioSource
		let audioURL: URL
		let duration: TimeInterval
		let startOffset: TimeInterval
		let text: String
		let timestampedSections: [TimestampedTranscriptSection]?
		let speakerSegments: [SpeakerAttributedSegment]?
		let displaySections: [TimestampedTranscriptSection]
	}

	/// A completed local transcription that is waiting for the parallel selected-text
	/// lookup. Keeping it in the reducer avoids pasting raw text before a detected
	/// selection can force the downstream refinement step.
	struct PendingSelectedTextTranscription: Equatable {
		let channels: [TranscribedAudioChannel]
		let microphoneAudioURL: URL
	}

	struct AgentHandoffPresentation: Equatable {
		var handoffID: UUID?
		var label: String
		/// Claude creates a coordinator in addition to the task agents. Keep it
		/// separate so launch progress only counts the handoffs the user can act on.
		var coordinatorThread: AgentHandoffThread?
		var threads: [AgentHandoffThread] = []
		var expectedTaskCount = 0
		/// The pill can depart once the coordinator request has been submitted. Task
		/// preparation then continues in the menu-bar handoff status list.
		var hasLaunched = false
		var isReady = false
		var isDeparting = false
		var isFlying = false

		init(
			handoffID: UUID? = nil,
			label: String,
			coordinatorThread: AgentHandoffThread? = nil,
			threads: [AgentHandoffThread] = [],
			expectedTaskCount: Int = 0,
			hasLaunched: Bool = false,
			isReady: Bool = false,
			isDeparting: Bool = false,
			isFlying: Bool = false
		) {
			self.handoffID = handoffID
			self.label = label
			self.coordinatorThread = coordinatorThread
			self.threads = threads
			self.expectedTaskCount = expectedTaskCount
			self.hasLaunched = hasLaunched
			self.isReady = isReady
			self.isDeparting = isDeparting
			self.isFlying = isFlying
		}
	}

	struct AgentHandoffProcessingStatus: Equatable, Identifiable {
		let id: UUID
		let provider: AgentHandoffRequest.Provider
		var label: String
		var coordinatorThread: AgentHandoffThread?
		var threads: [AgentHandoffThread] = []
		var expectedTaskCount = 0
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
		/// Captured at the finish gesture so settings edits cannot change an in-flight rewrite.
		var rewritePromptForRefinement: RewritePrompt?
		var completedTranscriptPresentation: CompletedTranscriptPresentation?
		/// The most recent ordinary result remains eligible for the quick
		/// post-hold refinement gesture even after it has been pasted.
		var recentCompletedTranscript: RecentCompletedTranscript?
		var agentHandoffPresentation: AgentHandoffPresentation?
		var agentHandoffProcessingStatuses: IdentifiedArrayOf<AgentHandoffProcessingStatus> = []
		/// Process-local handoff runs and the child threads Octo is actively observing.
		/// Unlike the durable journal, this cannot retain stale `.running` entries
		/// from an earlier app process.
		var agentHandoffActiveThreads: [UUID: Set<AgentHandoffThread>] = [:]
		/// Set only by the Shift-modified ending gesture for the active ordinary recording.
		var isAgentHandoffRequestedForActiveRecording = false
		var postHocRefinement: RecentCompletedTranscript?
		var pendingPressAndHoldActivationID: UUID?
		var pendingTerminalRefinementID: UUID?
		var activeRecordingHotkey: HotKey?
		var activeMinimumKeyTime: Double?
		var activeRecordingSource: RecordingSource?
		/// Snapshotted when recording begins so toggling the menu-bar control only
		/// affects later recordings, never an in-flight transcription.
		var activeSpeakerIdentificationEnabled = false
		/// Captured at recording start for the same in-flight consistency guarantee as speaker ID.
		var activeSystemAudioEnabled = false
		var activeSystemAudioStartOffset: TimeInterval = 0
	var error: String?
	var recordingStartTime: Date?
	var isLongRecordingCancellationConfirmationPresented = false
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
				case finishRecordingWithAgentHandoff
				case finishRecordingWithRewritePrompt(Int)
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
	case recordingStartFailed
	case recordingCheckpointStarted(RecordingCheckpoint)
	case recordingCheckpointFinalized(URL, TimeInterval, TranscriptStatus)

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)
		case hotKeyCancelled(RecordingSource)
		case hotKeyDiscarded(RecordingSource)
		case confirmLongRecordingCancellation
		case dismissLongRecordingCancellationConfirmation

    // Transcription result flow
	case transcriptionAudioCaptured(URL, TimeInterval)
	case systemAudioCaptureStarted(Date)
	case systemAudioCaptured(URL, TimeInterval, startOffset: TimeInterval)
	case transcriptionCheckpointPersisted(Transcript)
	case transcriptionResult([TranscribedAudioChannel], microphoneAudioURL: URL)
	case refinementResult(String, URL, TimeInterval)
    case transcriptionError(Error, URL?)
	case showError(String)
	case dismissError
	case pasteCompletedTranscript(String)
	case launchAgentHandoff(AgentHandoffRequest)
	case agentHandoffEvent(UUID, AgentHandoffEvent)
	case agentHandoffFailed(UUID?, String)
	case openAgentHandoff
	case dismissAgentHandoff
	case agentHandoffPresentationExpired
	case agentHandoffCollapseFinished
	case agentHandoffDepartureFinished
	#if DEBUG
	case debugAgentHandoffAnimation
	#endif
	case showCompletedTranscript(String)
	case copyCompletedTranscript
	case dismissCompletedTranscript
	case completedTranscriptPresentationExpired
	case completedTranscriptPresentationDismissalFinished

    // Model availability
    case modelMissing
  }

  enum CancelID: Hashable {
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
	case agentHandoff(UUID)
	case agentHandoffPresentation
	#if DEBUG
	case debugAgentHandoff
	#endif
		case selectedTextOnlyRefinement
		case selectedTextRefinement
		case errorPresentation
		case completedTranscriptPresentation
		case transcriptPaste
		case pendingPressAndHold
		case terminalRefinementHold
		case screenAwareActivation
			case screenContextCapture
  }

  @Dependency(\.transcription) var transcription
	@Dependency(\.speakerDiarization) var speakerDiarization
	@Dependency(\.speakerIntroduction) var speakerIntroduction
	@Dependency(\.recording) var recording
	@Dependency(\.systemAudioCapture) var systemAudioCapture
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
	@Dependency(\.agentHandoff) var agentHandoff

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
			state.hexSettings.refinementEnabled,
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

				case .finishRecordingWithAgentHandoff:
					guard state.hexSettings.agentHandoffEnabled,
						state.isRecording,
						state.activeRecordingSource == .regular
					else { return .none }
					state.pendingTerminalRefinementID = nil
					state.isAgentHandoffRequestedForActiveRecording = true
					deactivateScreenAwareMode(&state)
					// Keep the existing overlay alive while local transcription finishes.
					// Without this, its panel briefly receives the hidden state before the
					// handoff stream starts, making the progress indicator look like a new pill.
					state.agentHandoffPresentation = .init(label: "Processing")
					return .merge(
						.cancel(id: CancelID.terminalRefinementHold),
						.cancel(id: CancelID.screenAwareActivation),
						.send(.stopRecording)
					)

				case let .finishRecordingWithRewritePrompt(promptNumber):
					guard state.isRecording,
						state.activeRecordingSource == .regular,
						let prompt = state.hexSettings.rewritePrompt(at: promptNumber)
					else { return .none }
					state.pendingTerminalRefinementID = nil
					state.forcedRefinementMode = .refined
					state.rewritePromptForRefinement = prompt
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
					return .run { send in
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
						await send(.pasteCompletedTranscript(result))
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
				return .send(.transcriptionResult(pending.channels, microphoneAudioURL: pending.microphoneAudioURL))

			case let .selectedTextCaptured(selectedText):
				state.isCapturingSelectedTextForRefinement = false
				state.refinedHotKeyReleasedWhileCapturingSelection = false
				state.selectedTextForRefinement = selectedText
				if state.isRecording || state.isTranscribing {
					state.forcedRefinementMode = .refined
					if let pending = state.pendingSelectedTextTranscription {
						state.pendingSelectedTextTranscription = nil
						return .send(.transcriptionResult(pending.channels, microphoneAudioURL: pending.microphoneAudioURL))
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
				return .send(.pasteCompletedTranscript(result))

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

		case .recordingStartFailed:
			guard state.isRecording else { return .none }
			return .merge(
				handleDiscard(&state),
				.run { _ in
					soundEffect.play(.cancel)
				},
				.send(.showError("Microphone not available"))
			)

		case let .recordingCheckpointStarted(checkpoint):
			guard state.isRecording, state.hexSettings.saveTranscriptionHistory else { return .none }
			guard state.activeHistoryTranscriptID == nil else { return .none }
			let transcript = Transcript(
				timestamp: checkpoint.createdAt,
				text: "",
				audioPath: checkpoint.audioURL,
				duration: 0,
				sourceAppBundleID: state.sourceAppBundleID,
				sourceAppName: state.sourceAppName,
				status: .processing,
				audioChannels: [
					.init(
						source: .microphone,
						audioPath: checkpoint.audioURL,
						duration: 0
					)
				],
				recoverySessionID: checkpoint.sessionID
			)
			state.activeHistoryTranscriptID = transcript.id
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
			return .run { _ in
				for transcript in artifactsToDelete {
					try? await transcriptPersistence.deleteArtifacts(transcript)
				}
			}

		case let .recordingCheckpointFinalized(audioURL, duration, status):
			guard let historyID = state.activeHistoryTranscriptID else { return .none }
			let minimumDuration = max(state.hexSettings.minimumKeyTime, 1.0)
			if status == .cancelled, duration < minimumDuration {
				state.$transcriptionHistory.withLock { history in
					history.history.removeAll { $0.id == historyID }
				}
				state.activeHistoryTranscriptID = nil
				return .run { [recording] _ in
					FileManager.default.removeItemIfExists(at: audioURL)
					await recording.releaseRecordingSource(audioURL)
				}
			}

			state.$transcriptionHistory.withLock { history in
				guard let index = history.history.firstIndex(where: { $0.id == historyID }) else { return }
				history.history[index].audioPath = audioURL
				history.history[index].duration = duration
				if let channelIndex = history.history[index].audioChannels?.firstIndex(where: { $0.source == .microphone }) {
					history.history[index].audioChannels?[channelIndex].audioPath = audioURL
					history.history[index].audioChannels?[channelIndex].duration = duration
				}
				history.history[index].status = status
				// The final WAV is durable now, so this ordinary run can participate in
				// regular retention instead of being treated as an unresolved crash recovery.
				history.history[index].recoverySessionID = nil
			}
			if status != .processing {
				state.activeHistoryTranscriptID = nil
			}
			return .run { [recording] _ in
				await recording.releaseRecordingSource(audioURL)
			}

      // MARK: - Transcription Results

      case let .transcriptionAudioCaptured(audioURL, duration):
        state.activeTranscriptionAudioURL = audioURL
        state.activeTranscriptionDuration = duration
        return .none

		case let .systemAudioCaptureStarted(startedAt):
			state.activeSystemAudioStartOffset = max(
				0,
				state.recordingStartTime.map { startedAt.timeIntervalSince($0) } ?? 0
			)
			return .none

		case let .systemAudioCaptured(audioURL, duration, startOffset):
			guard let historyID = state.activeHistoryTranscriptID else { return .none }
			state.$transcriptionHistory.withLock { history in
				guard let index = history.history.firstIndex(where: { $0.id == historyID }) else { return }
				var channels = history.history[index].audioChannels ?? [
					.init(
						source: .microphone,
						audioPath: history.history[index].audioPath,
						duration: history.history[index].duration,
						text: history.history[index].rawText ?? history.history[index].text,
						timestampedSections: history.history[index].timestampedSections,
						speakerSegments: history.history[index].speakerSegments
					)
				]
				channels.removeAll { $0.source == .systemAudio }
				channels.append(.init(source: .systemAudio, audioPath: audioURL, duration: duration, startOffset: startOffset))
				history.history[index].audioChannels = channels
			}
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

	  case let .transcriptionResult(channels, microphoneAudioURL):
		return handleTranscriptionResult(&state, channels: channels, microphoneAudioURL: microphoneAudioURL)

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

		case let .launchAgentHandoff(request):
			let handoffID = uuid()
			state.agentHandoffActiveThreads[handoffID] = []
			state.agentHandoffProcessingStatuses.append(.init(
				id: handoffID,
				provider: request.provider,
				label: "Starting coordinator"
			))
			if state.agentHandoffPresentation == nil {
				state.agentHandoffPresentation = .init(
					handoffID: handoffID,
					label: "Processing"
				)
			} else if state.agentHandoffPresentation?.handoffID == nil {
				state.agentHandoffPresentation?.handoffID = handoffID
				state.agentHandoffPresentation?.label = "Processing"
			}
			return .run { [agentHandoff] send in
				do {
					for try await event in agentHandoff.launch(request) {
						await send(.agentHandoffEvent(handoffID, event))
					}
				} catch is CancellationError {
					return
				} catch {
					await send(.agentHandoffFailed(handoffID, error.localizedDescription))
				}
			}
			.cancellable(id: CancelID.agentHandoff(handoffID))

		case let .agentHandoffEvent(handoffID, event):
			if case let .childStarted(thread, _) = event,
				state.agentHandoffActiveThreads[handoffID] != nil
			{
				state.agentHandoffActiveThreads[handoffID, default: []].insert(thread)
			} else if case .completed = event {
				state.agentHandoffActiveThreads.removeValue(forKey: handoffID)
			}
			guard var processingStatus = state.agentHandoffProcessingStatuses[id: handoffID] else {
				return .none
			}
			var presentation = state.agentHandoffPresentation?.handoffID == handoffID
				? state.agentHandoffPresentation
				: nil
			var shouldBeginDeparture = false
			var shouldRemoveProcessingStatus = false
			switch event {
			case .received:
				processingStatus.label = "Starting coordinator"
			case .processing:
				processingStatus.label = "Starting coordinator"
			case .coordinatorSubmitted:
				processingStatus.label = "Waiting for tasks"
				if presentation?.hasLaunched == false {
					presentation?.hasLaunched = true
					presentation?.isReady = true
					presentation?.isDeparting = true
					shouldBeginDeparture = true
				}
			case let .coordinatorStarted(thread):
				processingStatus.coordinatorThread = thread
				processingStatus.label = "Waiting for tasks"
				if presentation?.hasLaunched == false {
					presentation?.hasLaunched = true
					presentation?.isReady = true
					presentation?.isDeparting = true
					shouldBeginDeparture = true
				}
			case let .tasksFound(count):
				processingStatus.expectedTaskCount = count
				processingStatus.label = "Waiting for tasks"
			case let .childStarted(thread, _):
				if !processingStatus.threads.contains(thread) {
					processingStatus.threads.append(thread)
				}
				shouldRemoveProcessingStatus = true

				// The journal has registered this child before emitting `childStarted`,
				// so it is now represented under Recent Handoffs. Remove the temporary
				// waiting row instead of keeping a stale "Launched" status around.
				if presentation?.hasLaunched == false {
					presentation?.hasLaunched = true
					presentation?.isReady = true
					presentation?.isDeparting = true
					shouldBeginDeparture = true
				}
			case .completed:
				processingStatus.label = "Handoff completed"
				shouldRemoveProcessingStatus = true
				if presentation?.hasLaunched == false {
					presentation?.hasLaunched = true
					presentation?.isReady = true
					presentation?.isDeparting = true
					shouldBeginDeparture = true
				}
			}

			if shouldRemoveProcessingStatus {
				state.agentHandoffProcessingStatuses.remove(id: handoffID)
			} else {
				state.agentHandoffProcessingStatuses[id: handoffID] = processingStatus
			}
			if let presentation {
				state.agentHandoffPresentation = presentation
			}
			return shouldBeginDeparture ? .send(.agentHandoffPresentationExpired) : .none

		case let .agentHandoffFailed(handoffID, message):
			if let handoffID {
				state.agentHandoffProcessingStatuses.remove(id: handoffID)
				state.agentHandoffActiveThreads.removeValue(forKey: handoffID)
			}
			let ownsPresentation = handoffID == nil
				|| state.agentHandoffPresentation?.handoffID == handoffID
			if ownsPresentation {
				state.agentHandoffPresentation = nil
			}
			return ownsPresentation
				? .merge(
					.cancel(id: CancelID.agentHandoffPresentation),
					.send(.showError(message))
				)
				: .send(.showError(message))

		case .openAgentHandoff:
			guard let presentation = state.agentHandoffPresentation,
				let thread = presentation.threads.first ?? presentation.coordinatorThread
			else { return .none }
			return .run { [agentHandoff] _ in
				await agentHandoff.open(thread)
			}

		case .dismissAgentHandoff:
			state.agentHandoffPresentation = nil
			return .cancel(id: CancelID.agentHandoffPresentation)

		case .agentHandoffPresentationExpired:
			guard state.agentHandoffPresentation?.hasLaunched == true else { return .none }
			state.agentHandoffPresentation?.isDeparting = true
			return .run { [clock] send in
				do {
					try await clock.sleep(for: .milliseconds(320))
					await send(.agentHandoffCollapseFinished)
				} catch {
					return
				}
			}
			.cancellable(id: CancelID.agentHandoffPresentation, cancelInFlight: true)

		case .agentHandoffCollapseFinished:
			guard state.agentHandoffPresentation?.isDeparting == true else { return .none }
			state.agentHandoffPresentation?.isFlying = true
			return .run { [clock] send in
				do {
					try await clock.sleep(for: .milliseconds(820))
					await send(.agentHandoffDepartureFinished)
				} catch {
					return
				}
			}
			.cancellable(id: CancelID.agentHandoffPresentation, cancelInFlight: true)

		case .agentHandoffDepartureFinished:
			guard state.agentHandoffPresentation?.isFlying == true else { return .none }
			state.agentHandoffPresentation = nil
			return .cancel(id: CancelID.agentHandoffPresentation)

		#if DEBUG
		case .debugAgentHandoffAnimation:
			transcriptionFeatureLogger.debug("Previewing the agent handoff departure animation")
			let handoffID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
			state.agentHandoffProcessingStatuses.remove(id: handoffID)
			state.agentHandoffProcessingStatuses.append(.init(
				id: handoffID,
				provider: .codex,
				label: "Starting coordinator"
			))
			state.agentHandoffPresentation = .init(
				handoffID: handoffID,
				label: "Processing"
			)
			return .run { [clock] send in
				do {
					try await clock.sleep(for: .milliseconds(300))
					await send(.agentHandoffEvent(handoffID, .coordinatorSubmitted))
					try await clock.sleep(for: .milliseconds(700))
					await send(.agentHandoffEvent(handoffID, .tasksFound(2)))
					try await clock.sleep(for: .milliseconds(650))
					await send(.agentHandoffEvent(
						handoffID,
						.childStarted(.codex("debug-first"), ordinal: 1)
					))
				} catch {
					return
				}
			}
			.cancellable(id: CancelID.debugAgentHandoff, cancelInFlight: true)
		#endif

		case let .pasteCompletedTranscript(text):
			return .run { [pasteboard, soundEffect] send in
				switch await pasteboard.focusedEditableDestination() {
				case .available:
					await pasteboard.paste(text)
					soundEffect.play(.pasteTranscript)
				case .absent, .indeterminate:
					await send(.showCompletedTranscript(text))
				}
			}
			.cancellable(id: CancelID.transcriptPaste, cancelInFlight: true)

		case let .showCompletedTranscript(text):
			state.completedTranscriptPresentation = .expanded(text)
			return .cancel(id: CancelID.completedTranscriptPresentation)

		case .copyCompletedTranscript:
			guard let presentation = state.completedTranscriptPresentation,
				case let .expanded(text) = presentation
			else { return .none }
			state.completedTranscriptPresentation = .copied(text)
			return .merge(
				.run { [pasteboard] _ in
					await pasteboard.copy(text)
				},
				.run { [clock] send in
					do {
						try await clock.sleep(for: .seconds(2))
						await send(.completedTranscriptPresentationExpired)
					} catch {
						return
					}
				}
				.cancellable(id: CancelID.completedTranscriptPresentation, cancelInFlight: true)
			)

		case .dismissCompletedTranscript:
			state.completedTranscriptPresentation = nil
			return .cancel(id: CancelID.completedTranscriptPresentation)

		case .completedTranscriptPresentationExpired:
			guard case let .copied(text) = state.completedTranscriptPresentation else { return .none }
			state.completedTranscriptPresentation = .hidingCopied(text)
			return .run { [clock] send in
				do {
					try await clock.sleep(for: .milliseconds(220))
					await send(.completedTranscriptPresentationDismissalFinished)
				} catch {
					return
				}
			}
			.cancellable(id: CancelID.completedTranscriptPresentation, cancelInFlight: true)

		case .completedTranscriptPresentationDismissalFinished:
			guard case .hidingCopied = state.completedTranscriptPresentation else { return .none }
			state.completedTranscriptPresentation = nil
			return .cancel(id: CancelID.completedTranscriptPresentation)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

		case .cancel:
			if state.completedTranscriptPresentation != nil {
				return .send(.dismissCompletedTranscript)
			}
			if state.agentHandoffPresentation != nil {
				state.agentHandoffPresentation = nil
				return .cancel(id: CancelID.agentHandoffPresentation)
			}
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
			if state.isRecording,
				let recordingStartTime = state.recordingStartTime,
				now.timeIntervalSince(recordingStartTime) >= TimeInterval(state.hexSettings.longRecordingConfirmationThresholdMinutes * 60)
			{
				state.isLongRecordingCancellationConfirmationPresented = true
				return .none
			}
			return handleCancel(&state)

		case .confirmLongRecordingCancellation:
			guard state.isLongRecordingCancellationConfirmationPresented, state.isRecording else { return .none }
			state.isLongRecordingCancellationConfirmationPresented = false
			return handleCancel(&state)

		case .dismissLongRecordingCancellationConfirmation:
			state.isLongRecordingCancellationConfirmationPresented = false
			return .none

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
		let rewritePromptHoldTracker = RewritePromptHoldTracker()

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
			if isSettingHotKey {
	          return false
	        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
		let supportsScreenAwareGesture = hexSettings.refinementEnabled
			&& ScreenAwareActivation.isAvailable(with: hexSettings)
	        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled
	          && hexSettings.useDoubleTapOnly
	        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
	        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
	        hotKeyProcessor.allowLongPressForOnDemand = hexSettings.allowLongPressForOnDemand
		hotKeyProcessor.lockingHoldDuration = hexSettings.refinementEnabled
			? max(hexSettings.minimumKeyTime, ScreenAwareActivation.minimumHoldDuration)
			: nil
	        hotKeyProcessor.screenAwareSecondTapEnabled = supportsScreenAwareGesture
		hotKeyProcessor.postHoldRefinementEnabled = hexSettings.refinementEnabled
			&& !hexSettings.doubleTapLockEnabled
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

		switch inputEvent {
		case .keyboard(let keyEvent):
		  // Keep this development shortcut nearby for future animation work, but
		  // leave it disabled so Command-1 continues through to the active app.
		  // #if DEBUG
		  // if keyEvent.physicalKey == .one,
		  // 	keyEvent.modifiers.matchesExactly([.command])
		  // {
		  // 	if keyEvent.isKeyDown {
		  // 		Task { await send(.debugAgentHandoffAnimation) }
		  // 	}
		  // 	return true
		  // }
		  // #endif

		  if rewritePromptHoldTracker.hasTriggered() {
			  hotKeyProcessor.reset()
		  }

		  if hexSettings.refinementEnabled,
			 let promptNumber = rewritePromptNumber(for: keyEvent.physicalKey),
			 keyEvent.modifiers.isEmpty
		  {
			  if keyEvent.isKeyDown,
				 hotKeyProcessor.isMatched,
				 hexSettings.rewritePrompt(at: promptNumber) != nil,
				 let key = keyEvent.physicalKey
			  {
				  if rewritePromptHoldTracker.matches(key) {
					  return true
				  }
				  let hold = RewritePromptHold(key: key)
				  let duration = max(
					hexSettings.minimumKeyTime,
					ScreenAwareActivation.minimumHoldDuration
				  )
				  let task = Task {
					  do {
						  try await Task.sleep(for: .seconds(duration))
					  } catch {
						  return
					  }
					  guard !Task.isCancelled else { return }
					  hold.markTriggered()
					  await send(.finishRecordingWithRewritePrompt(promptNumber))
				  }
				  rewritePromptHoldTracker.replace(with: hold, task: task)
				  return true
			  }

			  if keyEvent.isKeyUp,
				 let activeHold = rewritePromptHoldTracker.take(for: keyEvent.physicalKey)
			  {
				  activeHold.task.cancel()
				  if activeHold.hold.hasTriggered() {
					  hotKeyProcessor.reset()
					  return true
				  }
				  // Only a short tap gets a replacement key-down. Returning `false`
				  // lets the physical key-up reach the focused app; long holds above
				  // suppress both events and finish with their rewrite prompt instead.
				  keyEventMonitor.replayKeyDown(activeHold.hold.key)
				  return false
			  }
		  }

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


		  if hexSettings.agentHandoffEnabled {
		  switch agentHandoffEndingGesture(
			for: keyEvent,
			hotkey: hexSettings.hotkey,
			processorState: hotKeyProcessor.state
		  ) {
		  case .finish:
			hotKeyProcessor.reset()
			Task { await send(.finishRecordingWithAgentHandoff) }
			return false
		  case .consume:
			return false
		  case .none:
			break
		  }
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
			// Screen Aware is decided by the hold timer, never by the key-up event.
			Task { await send(.cancelScreenAwareActivation) }
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
	state.isLongRecordingCancellationConfirmationPresented = false
	state.completedTranscriptPresentation = nil
	state.agentHandoffPresentation = nil
	state.isAgentHandoffRequestedForActiveRecording = false
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
		state.rewritePromptForRefinement = nil
	state.activeRecordingHotkey = state.hexSettings.hotkey
	state.activeMinimumKeyTime = state.hexSettings.minimumKeyTime
		state.activeRecordingSource = source
		state.activeSpeakerIdentificationEnabled = state.hexSettings.speakerIdentificationEnabled
		state.activeSystemAudioEnabled = state.hexSettings.includeSystemAudio
		state.activeSystemAudioStartOffset = 0
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
			.cancel(id: CancelID.completedTranscriptPresentation),
			.cancel(id: CancelID.agentHandoffPresentation),
			.cancel(id: CancelID.transcriptPaste),
			.cancel(id: CancelID.recordingCleanup),
			.cancel(id: CancelID.terminalRefinementHold),
			.cancel(id: CancelID.screenAwareActivation),
			cancelsScreenContextCapture ? .cancel(id: CancelID.screenContextCapture) : .none,
		.run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep, includeSystemAudio = state.activeSystemAudioEnabled] send in
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
			let startResult = await recording.startRecording()
			guard !Task.isCancelled else { return }
			switch startResult {
			case let .started(checkpoint):
				await send(.recordingCheckpointStarted(checkpoint))
				if includeSystemAudio {
					switch await systemAudioCapture.startCapture(checkpoint.sessionID) {
					case let .started(startedAt):
						await send(.systemAudioCaptureStarted(startedAt))
					case .permissionDenied:
						await send(.showError("System audio needs Screen Recording permission. Microphone recording will continue."))
					case .failed:
						await send(.showError("System audio could not be started. Microphone recording will continue."))
					}
				}
			case .microphoneUnavailable:
				await send(.recordingStartFailed)
			case .failed:
				return
			}
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

	  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
	state.isLongRecordingCancellationConfirmationPresented = false
    
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
	let includeSystemAudio = state.activeSystemAudioEnabled
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
			state.rewritePromptForRefinement = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
		state.isAgentHandoffRequestedForActiveRecording = false
		state.activeSystemAudioEnabled = false
		state.activeSystemAudioStartOffset = 0
      // Recording was below minimum duration. If it captured at least 1.0s of audio we still
      // persist it as a cancelled entry so the user can retry; otherwise discard silently
      // (covers accidental modifier-only taps).
      transcriptionFeatureLogger.notice("Short recording per decision \(String(describing: decision)); duration=\(String(format: "%.3f", duration))s")
	      let sourceAppBundleID = state.sourceAppBundleID
      let sourceAppName = state.sourceAppName
      let transcriptionHistory = state.$transcriptionHistory
		  let historyCheckpointID = state.activeHistoryTranscriptID
	      return .merge(
	        .cancel(id: CancelID.recordingStart),
			.cancel(id: CancelID.screenContextCapture),
		.run { [duration, sleepManagement, includeSystemAudio] send in
			await selectedText?.cancel()
			await sleepManagement.allowSleep()
			if includeSystemAudio, case let .captured(systemAudioURL, _) = await systemAudioCapture.stopCapture() {
				FileManager.default.removeItemIfExists(at: systemAudioURL)
			}
		  let stopResult = await recording.stopRecording()
		  guard !Task.isCancelled else { return }
		  switch stopResult {
		  case let .captured(url):
			if historyCheckpointID != nil {
				await send(.recordingCheckpointFinalized(url, duration, .cancelled))
			} else {
				await persistOrDiscard(
					status: .cancelled,
					audioURL: url,
					duration: duration,
					sourceAppBundleID: sourceAppBundleID,
					sourceAppName: sourceAppName,
					transcriptionHistory: transcriptionHistory
				)
			}
		  case let .recovered(url, error):
			await send(.recordingCheckpointFinalized(url, duration, .processing))
			await send(.transcriptionAudioCaptured(url, duration))
			await send(.transcriptionError(error, url))
		  case .ignored, .failed:
			return
		  }
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
	let historyCheckpointID = state.activeHistoryTranscriptID
	let selectedTextForCheckpoint = state.selectedTextForRefinement?.text
	let screenContextForCheckpoint = state.screenContextForRefinement
	let screenAwareInputSourceForCheckpoint = state.screenAwareInputSourceForRefinement
	let stagedScreenshotPath = state.stagedScreenContextScreenshotPath
	let sourceAppBundleID = state.sourceAppBundleID
	let sourceAppName = state.sourceAppName
	let speakerIdentificationEnabled = state.activeSpeakerIdentificationEnabled
	let speakerDiarizationProvider = state.hexSettings.speakerDiarizationProvider
	let speakerIntroductionSettings = state.hexSettings
	let systemAudioStartOffset = state.activeSystemAudioStartOffset

    return .merge(
      .cancel(id: CancelID.recordingStart),
		.run { [duration, sleepManagement, transcriptPersistence, speakerDiarization, speakerIntroduction, systemAudioCapture] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

		var unownedAudioURL: URL?
		var capturedAudioURL: URL?
		var transientSystemAudioURL: URL?
		defer {
          if let unownedAudioURL {
            FileManager.default.removeItemIfExists(at: unownedAudioURL)
				RecordingRecoveryStore.releaseSource(forFinalAudioURL: unownedAudioURL)
			}
			if let transientSystemAudioURL {
				FileManager.default.removeItemIfExists(at: transientSystemAudioURL)
			}
		}
		do {
			let systemAudioStopResult = includeSystemAudio
				? await systemAudioCapture.stopCapture()
				: .ignored(.noActiveCapture)
			let stopResult = await recording.stopRecording()
          let capturedURL: URL
          switch stopResult {
		  case let .captured(url):
			capturedURL = url
		  case let .recovered(url, error):
			await send(.recordingCheckpointFinalized(url, duration, .processing))
			await send(.transcriptionAudioCaptured(url, duration))
			await send(.transcriptionError(error, url))
			return
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
		  var transcriptionChannels: [(source: TranscriptAudioSource, audioURL: URL, duration: TimeInterval, startOffset: TimeInterval)] = [
			  (.microphone, capturedURL, duration, 0)
		  ]

		  // The audio file is the first durable checkpoint. It is stored before
		  // transcription begins, so a crash, cancellation, or provider failure can
		  // never discard the voice message that produced the run.
		  var durableHistoryID = historyCheckpointID
		  if shouldCreateHistoryCheckpoint, historyCheckpointID == nil {
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
				  durableHistoryID = checkpoint.id
				  await send(.transcriptionCheckpointPersisted(checkpoint))
			  } catch {
				  transcriptionFeatureLogger.error("Failed to persist audio checkpoint: \(error.localizedDescription, privacy: .private)")
			  }
		  }
		  if historyCheckpointID != nil {
			  // The row was inserted when durable PCM opened. The WAV now exists at its
			  // predicted path, so History owns it rather than this effect's cleanup defer.
			  unownedAudioURL = nil
			  await send(.recordingCheckpointFinalized(capturedURL, duration, .processing))
		  }
		  transcriptionChannels[0].audioURL = audioURLForTranscription

		  if case let .captured(systemAudioURL, systemAudioDuration) = systemAudioStopResult {
			  let systemAudioURLForTranscription = systemAudioURL
			  transientSystemAudioURL = shouldCreateHistoryCheckpoint ? nil : systemAudioURL
			  if durableHistoryID != nil {
				  // Keep the recovery-named CAF as the one authoritative file. Moving it to a
				  // second name before History is updated would create a crash window where the
				  // bytes exist but neither History nor relaunch recovery can find them.
				  transientSystemAudioURL = nil
				  await send(.systemAudioCaptured(systemAudioURL, systemAudioDuration, startOffset: systemAudioStartOffset))
			  }
			  transcriptionChannels.append((.systemAudio, systemAudioURLForTranscription, systemAudioDuration, systemAudioStartOffset))
		  } else if case let .failed(message) = systemAudioStopResult {
			  transcriptionFeatureLogger.warning("System audio capture ended without a transcript: \(message, privacy: .private)")
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

		  var channelResults = [TranscribedAudioChannel]()
		  for channel in transcriptionChannels {
			  do {
				  var output = try await transcription.transcribe(channel.audioURL, model, decodeOptions) { _ in }
				  var introducedSpeakerIDs = Set<String>()

				  if speakerIdentificationEnabled, !output.words.isEmpty, output.speakerAttribution == nil {
					  do {
						  let diarization: SpeakerDiarizationOutput
						  if let suppliedDiarization = output.diarization {
							  diarization = suppliedDiarization
						  } else {
							  diarization = try await speakerDiarization.analyze(channel.audioURL, speakerDiarizationProvider)
						  }
						  let introductionContexts = SpeakerIdentification.introductionContexts(
							  transcription: output,
							  diarization: diarization
						  )
						  let introductions: [SpeakerIntroduction]
						  do {
							  introductions = try await speakerIntroduction.classify(introductionContexts, speakerIntroductionSettings)
						  } catch {
							  transcriptionFeatureLogger.warning("Speaker introduction classification failed: \(error.localizedDescription, privacy: .private)")
							  introductions = []
						  }
						  introducedSpeakerIDs = Set(introductions.map(\.speakerID))
						  @Shared(.speakerVoiceLibrary) var voiceLibrary: SpeakerVoiceLibrary
						  let savedLibrary = $voiceLibrary.withLock { $0 }
						  let verifiedProfileIDs = await verifyKnownSpeakerMatches(
							  diarization: diarization,
							  library: savedLibrary,
							  sourceURL: channel.audioURL,
							  provider: speakerDiarizationProvider,
							  analyze: speakerDiarization.analyze
						  )
						  output.speakerAttribution = $voiceLibrary.withLock { library in
							  SpeakerIdentification.attribute(
								  transcription: output,
								  diarization: diarization,
								  library: &library,
								  now: Date(),
								  introductions: introductions,
								  verifiedProfileIDs: verifiedProfileIDs
							  )
						  }
					  } catch {
						  // Speaker identification is optional for each independently captured channel.
						  transcriptionFeatureLogger.warning("Speaker identification failed: \(error.localizedDescription, privacy: .private)")
				  }
				  }

				  if let attribution = output.speakerAttribution {
					  await storeSpeakerVoiceSamples(
						  from: attribution,
						  sourceURL: channel.audioURL,
						  replacingSamplesForSpeakerIDs: introducedSpeakerIDs
					  )
				  }

			  transcriptionFeatureLogger.notice("Transcribed \(channel.source.rawValue, privacy: .public) audio to text length \(output.text.count)")
				  channelResults.append(.init(source: channel.source, audioURL: channel.audioURL, duration: channel.duration, startOffset: channel.startOffset, output: output))
			  } catch {
				  guard channel.source == .systemAudio else { throw error }
				  // A system-audio failure must not throw away a successful microphone transcription.
				  transcriptionFeatureLogger.warning("System audio transcription failed: \(error.localizedDescription, privacy: .private)")
			  }
		  }

		  guard channelResults.contains(where: { $0.source == .microphone }) else {
			  throw RecordingFailure.noCapturedAudio
		  }
		  await send(.transcriptionResult(channelResults, microphoneAudioURL: audioURLForTranscription))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription, privacy: .private)")
          await send(.transcriptionError(error, capturedAudioURL))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }
}

/// Retain the first local clip for each saved profile. This runs after speaker
/// matching, so no audio is kept for anonymous labels or repeatedly added later.
private func storeSpeakerVoiceSamples(
	from attribution: SpeakerAttributedTranscript,
	sourceURL: URL,
	replacingSamplesForSpeakerIDs: Set<String>
) async {
	var candidates = [UUID: SpeakerAttributedSegment]()
	for segment in attribution.segments {
		guard let profileID = segment.profileID else { continue }
		let existingDuration = candidates[profileID].map { $0.endTime - $0.startTime } ?? 0
		if segment.endTime - segment.startTime > existingDuration {
			candidates[profileID] = segment
		}
	}
	@Shared(.speakerVoiceLibrary) var voiceLibrary: SpeakerVoiceLibrary
	var samplesToDelete = [SpeakerVoiceSample]()
	let profilesNeedingSample = $voiceLibrary.withLock { library -> Set<UUID> in
		var profileIDs = Set<UUID>()
		for index in library.profiles.indices {
			let storedSamples = library.profiles[index].audioSamples ?? []
			let usableSamples = storedSamples.filter { FileManager.default.fileExists(atPath: $0.audioURL.path) }
			samplesToDelete.append(contentsOf: storedSamples.filter { !FileManager.default.fileExists(atPath: $0.audioURL.path) })
			if let firstSample = usableSamples.first {
				library.profiles[index].audioSamples = [firstSample]
				samplesToDelete.append(contentsOf: usableSamples.dropFirst())
			} else {
				library.profiles[index].audioSamples = []
				profileIDs.insert(library.profiles[index].id)
			}
		}
		return profileIDs
	}
	SpeakerVoiceSampleStore.delete(samplesToDelete)
	let profileIDsReplacingSample = Set(attribution.segments.compactMap { segment -> UUID? in
		guard replacingSamplesForSpeakerIDs.contains(segment.speakerID) else { return nil }
		return segment.profileID
	})

	var captured = [(profileID: UUID, sample: SpeakerVoiceSample)]()
	for (profileID, segment) in candidates {
		guard profilesNeedingSample.contains(profileID) || profileIDsReplacingSample.contains(profileID) else { continue }
		do {
			guard let sample = try await SpeakerVoiceSampleStore.capture(
				from: sourceURL,
				profileID: profileID,
				startTime: segment.startTime,
				endTime: segment.endTime
			) else { continue }
			captured.append((profileID, sample))
		} catch {
			transcriptionFeatureLogger.warning("Could not retain speaker audio sample: \(error.localizedDescription, privacy: .private)")
		}
	}

	guard !captured.isEmpty else { return }
	samplesToDelete = []
	$voiceLibrary.withLock { library in
		for (profileID, sample) in captured {
			guard let index = library.profiles.firstIndex(where: { $0.id == profileID }) else {
				samplesToDelete.append(sample)
				continue
			}
			let hasSavedSample = (library.profiles[index].audioSamples ?? [])
				.contains { FileManager.default.fileExists(atPath: $0.audioURL.path) }
			if profileIDsReplacingSample.contains(profileID) {
				samplesToDelete.append(contentsOf: library.profiles[index].audioSamples ?? [])
				library.profiles[index].audioSamples = [sample]
			} else if hasSavedSample {
				samplesToDelete.append(sample)
			} else {
				library.profiles[index].audioSamples = [sample]
			}
		}
	}
	SpeakerVoiceSampleStore.delete(samplesToDelete)
}

/// Verifies the most likely saved voices in a single diarization run. Cluster IDs
/// are local to one run, so placing a retained sample next to the new turn gives a
/// much stronger signal than comparing embeddings produced in separate runs.
private func verifyKnownSpeakerMatches(
	diarization: SpeakerDiarizationOutput,
	library: SpeakerVoiceLibrary,
	sourceURL: URL,
	provider: SpeakerDiarizationProvider,
	analyze: @escaping @Sendable (URL, SpeakerDiarizationProvider) async throws -> SpeakerDiarizationOutput
) async -> [String: UUID] {
	let candidates = SpeakerIdentification.rankedVoiceMatchCandidates(
		diarization: diarization,
		library: library
	)
	guard !candidates.isEmpty else { return [:] }

	var verified = [String: UUID]()
	for (speakerID, speakerCandidates) in Dictionary(grouping: candidates, by: \.speakerID) {
		guard let candidateSegment = diarization.segments
			.filter({ $0.speakerID == speakerID })
			.max(by: { ($0.endTime - $0.startTime) < ($1.endTime - $1.startTime) })
		else { continue }

		let references = speakerCandidates.compactMap { candidate -> SpeakerVoiceComparisonReference? in
			guard let profile = library.profiles.first(where: { $0.id == candidate.profileID }),
				let sample = (profile.audioSamples ?? [])
					.first(where: { FileManager.default.fileExists(atPath: $0.audioURL.path) })
			else { return nil }
			return .init(profileID: profile.id, audioURL: sample.audioURL)
		}
		guard let input = try? await SpeakerVoiceSampleStore.comparisonInput(
			references: references,
			candidateURL: sourceURL,
			candidateStartTime: candidateSegment.startTime,
			candidateEndTime: candidateSegment.endTime
		) else { continue }
		defer { FileManager.default.removeItemIfExists(at: input.audioURL) }

		do {
			let jointDiarization = try await analyze(input.audioURL, provider)
			guard let candidateCluster = dominantCluster(
				in: jointDiarization,
				startTime: input.candidateStartTime,
				endTime: input.candidateEndTime
			) else { continue }
			let matchedProfiles = input.referenceRanges.compactMap { range -> UUID? in
				dominantCluster(in: jointDiarization, startTime: range.startTime, endTime: range.endTime) == candidateCluster
					? range.profileID
					: nil
			}
			if matchedProfiles.count == 1, let profileID = matchedProfiles.first {
				verified[speakerID] = profileID
			}
		} catch {
			transcriptionFeatureLogger.warning("Speaker reference comparison failed: \(error.localizedDescription, privacy: .private)")
		}
	}
	return verified
}

private func dominantCluster(
	in diarization: SpeakerDiarizationOutput,
	startTime: TimeInterval,
	endTime: TimeInterval
) -> String? {
	guard endTime > startTime else { return nil }
	let overlapBySpeaker = diarization.segments.reduce(into: [String: TimeInterval]()) { result, segment in
		let overlap = max(0, min(endTime, segment.endTime) - max(startTime, segment.startTime))
		guard overlap > 0 else { return }
		result[segment.speakerID, default: 0] += overlap
	}
	guard let dominant = overlapBySpeaker.max(by: { $0.value < $1.value }),
		dominant.value >= min(0.5, (endTime - startTime) * 0.25)
	else { return nil }
	return dominant.key
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
	func agentHandoffRequest(
		for transcript: String,
		selectedText: String?,
		screenContext: ScreenContext?,
		screenAwareInputSource: ScreenAwareInputSource?,
		settings: HexSettings
	) -> AgentHandoffRequest? {
		guard settings.agentHandoffEnabled else { return nil }
		let provider: AgentHandoffRequest.Provider?
		switch settings.agentHandoffProvider {
		case .codexCLI:
			provider = .codex
		case .claudeCLI:
			provider = .claude
		default:
			provider = nil
		}
		guard let provider else { return nil }
		return .init(
			provider: provider,
			modelID: settings.agentHandoffModelID,
			reasoningEffort: settings.agentHandoffReasoningEffort,
			transcript: transcript,
			selectedText: selectedText,
			screenContext: screenContext,
			screenAwareInputSource: screenAwareInputSource ?? settings.screenAwareInputSource
		)
	}

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
	state.rewritePromptForRefinement = nil
    state.activeRecordingHotkey = nil
    state.activeMinimumKeyTime = nil
    state.activeRecordingSource = nil
	state.isAgentHandoffRequestedForActiveRecording = false

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
		channels: [TranscribedAudioChannel],
		microphoneAudioURL: URL
	) -> Effect<Action> {
		guard channels.contains(where: { $0.source == .microphone }) else { return .none }
		let audioURL = microphoneAudioURL
		let rawResult = channels.map { $0.output.canonicalText }.filter { !$0.isEmpty }.joined(separator: " ")
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
		state.pendingSelectedTextTranscription = .init(channels: channels, microphoneAudioURL: microphoneAudioURL)
      return .none
    }
    let duration = state.activeTranscriptionDuration
      ?? state.recordingStartTime.map { now.timeIntervalSince($0) }
      ?? 0

    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
	if ForceQuitCommandDetector.matches(rawResult) {
		  state.activeTranscriptionAudioURL = nil
		  state.activeTranscriptionDuration = nil
		  state.screenContextForRefinement = nil
		  state.screenContextCaptureID = nil
		  state.pendingScreenAwareTranscription = nil
		  state.pendingSelectedTextTranscription = nil
	  state.forcedRefinementMode = nil
	  state.rewritePromptForRefinement = nil
	  state.activeRecordingHotkey = nil
	  state.activeMinimumKeyTime = nil
	  state.activeRecordingSource = nil
	  state.isAgentHandoffRequestedForActiveRecording = false
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

		let processedChannels = channels.map { processTranscribedAudioChannel($0, state: state) }
		let unifiedSections = processedChannels
			.flatMap(\.displaySections)
			.sorted {
				if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
				if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
				return ($0.audioSource?.rawValue ?? "") < ($1.audioSource?.rawValue ?? "")
			}
		let modifiedResult = TimestampedTranscriptSectionBuilder.renderedText(from: unifiedSections)
			.isEmpty
			? processedChannels.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
			: TimestampedTranscriptSectionBuilder.renderedText(from: unifiedSections)

	// A silent selected-text recording still has useful work to do: apply the configured
    // refinement prompt to the captured selection without an extra spoken instruction.
	guard !modifiedResult.isEmpty || selectedText != nil || screenContext != nil || state.screenContextCaptureID != nil else {
      return handleEmptyTranscriptionResult(&state, audioURL: audioURL)
    }

	if !rawResult.isEmpty {
	  transcriptionFeatureLogger.info("Raw transcription: '\(rawResult, privacy: .private)'")
    }
	if processedChannels.contains(where: { $0.speakerSegments?.isEmpty == false }) {
		transcriptionFeatureLogger.info("Captured speaker labels for \(processedChannels.count) audio channel(s); processed length=\(modifiedResult.count)")
	} else if modifiedResult != rawResult {
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
		let isAgentHandoffRequested = state.isAgentHandoffRequestedForActiveRecording
	    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory
		// Local transcription is independently durable before optional AI work begins.
		if let historyCheckpointID = state.activeHistoryTranscriptID {
			state.$transcriptionHistory.withLock { history in
				guard let index = history.history.firstIndex(where: { $0.id == historyCheckpointID }) else { return }
				history.history[index].rawText = modifiedResult
				history.history[index].timestampedSections = unifiedSections.isEmpty ? nil : unifiedSections
				history.history[index].speakerSegments = nil
				var storedChannels = history.history[index].audioChannels ?? []
				for channel in processedChannels {
					let stored = TranscriptAudioChannel(
						source: channel.source,
						audioPath: channel.audioURL,
						duration: channel.duration,
						startOffset: channel.startOffset,
						text: channel.text,
						timestampedSections: channel.timestampedSections,
						speakerSegments: channel.speakerSegments
					)
					if let channelIndex = storedChannels.firstIndex(where: { $0.source == channel.source }) {
						storedChannels[channelIndex] = stored
					} else {
						storedChannels.append(stored)
					}
				}
				history.history[index].audioChannels = storedChannels
				history.history[index].selectedText = selectedText?.text ?? history.history[index].selectedText
			}
		}

		// Agent Handoff is a distinct destination for the completed local transcript:
		// keep the normal durable History behavior, but never run refinement or paste
		// the text back into the focused app. The selected native provider receives the
		// full refinement-equivalent input once as persistent child task(s).
		if isAgentHandoffRequested {
			let historyCheckpointID = state.activeHistoryTranscriptID
			let handoffRequest = agentHandoffRequest(
				for: modifiedResult,
				selectedText: selectedText?.text,
				screenContext: screenContext,
				screenAwareInputSource: state.screenAwareInputSourceForRefinement,
				settings: state.hexSettings
			)
			state.activeHistoryTranscriptID = nil
			state.isAgentHandoffRequestedForActiveRecording = false
			state.forcedRefinementMode = nil
			state.rewritePromptForRefinement = nil
			state.activeRecordingHotkey = nil
			state.activeMinimumKeyTime = nil
			state.activeRecordingSource = nil
			state.activeSystemAudioEnabled = false
			state.activeSystemAudioStartOffset = 0
			state.activeTranscriptionAudioURL = nil
			state.activeTranscriptionDuration = nil
			state.recentCompletedTranscript = nil
			return .run { send in
				await finalizeRecordingAndStoreTranscript(
					result: modifiedResult,
					duration: duration,
					sourceAppBundleID: sourceAppBundleID,
					sourceAppName: sourceAppName,
					audioURL: audioURL,
					transcriptionHistory: transcriptionHistory,
					selectedText: selectedText,
					rawTranscript: modifiedResult,
					timestampedSections: unifiedSections.isEmpty ? nil : unifiedSections,
					speakerSegments: nil,
					historyCheckpointID: historyCheckpointID
				)
				guard let handoffRequest else {
					await send(.agentHandoffFailed(nil, AgentHandoffError.providerUnavailable.localizedDescription))
					return
				}
				guard handoffRequest.hasUserRequest else {
					await send(.agentHandoffFailed(nil, AgentHandoffError.noUserRequest.localizedDescription))
					return
				}
				await send(.launchAgentHandoff(handoffRequest))
			}
			.cancellable(id: CancelID.transcription)
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
		state.rewritePromptForRefinement = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
		state.isAgentHandoffRequestedForActiveRecording = false
		state.activeSystemAudioEnabled = false
		state.activeSystemAudioStartOffset = 0
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
			timestampedSections: unifiedSections.isEmpty ? nil : unifiedSections,
			speakerSegments: nil,
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

	func processTranscribedAudioChannel(
		_ channel: TranscribedAudioChannel,
		state: State
	) -> ProcessedAudioChannel {
		let output = channel.output
		let rawText = output.canonicalText
		let timestampedSections: [TimestampedTranscriptSection]
		let speakerSegments: [SpeakerAttributedSegment]?
		let text: String

		if rawText.isEmpty || state.isRemappingScratchpadFocused {
			timestampedSections = output.timestampedSections.map { section in
				var section = section
				section.audioSource = channel.source
				return section
			}
			speakerSegments = output.speakerAttribution?.segments
			text = rawText
		} else {
			let settings = state.hexSettings
			func format(_ text: String) -> String {
				let remapped = WordRemappingApplier.apply(text, remappings: settings.wordRemappings)
				let removed = settings.wordRemovalsEnabled
					? WordRemovalApplier.apply(remapped, removals: settings.wordRemovals)
					: remapped
				return TranscriptFormattingApplier.apply(
					removed,
					lowercase: settings.lowercaseTranscripts,
					removePunctuation: settings.removePunctuation
				)
			}

			timestampedSections = output.timestampedSections.compactMap { section in
				var section = section
				section.text = format(section.text)
				section.audioSource = channel.source
				return section.text.isEmpty ? nil : section
			}
			speakerSegments = output.speakerAttribution?.segments.compactMap { segment in
				var segment = segment
				segment.text = format(segment.text)
				return segment.text.isEmpty ? nil : segment
			}
			text = timestampedSections.isEmpty
				? format(rawText)
				: TimestampedTranscriptSectionBuilder.renderedText(from: timestampedSections)
		}

		let nonEmptySpeakerSegments = speakerSegments?.isEmpty == false ? speakerSegments : nil
		let displaySections: [TimestampedTranscriptSection]
		if let nonEmptySpeakerSegments {
			displaySections = nonEmptySpeakerSegments.map {
				.init(
					text: $0.text,
					startTime: $0.startTime + channel.startOffset,
					endTime: $0.endTime + channel.startOffset,
					audioSource: channel.source,
					speakerName: $0.speakerName
				)
			}
		} else {
			displaySections = timestampedSections.map { section in
				var section = section
				section.startTime += channel.startOffset
				section.endTime += channel.startOffset
				return section
			}
		}
		let fallbackDisplaySections = displaySections.isEmpty && !text.isEmpty
			? [
				TimestampedTranscriptSection(
					text: text,
					startTime: channel.startOffset,
					endTime: channel.startOffset + channel.duration,
					audioSource: channel.source
				)
			]
			: displaySections

		return .init(
			source: channel.source,
			audioURL: channel.audioURL,
			duration: channel.duration,
			startOffset: channel.startOffset,
			text: text,
			timestampedSections: timestampedSections.isEmpty ? nil : timestampedSections,
			speakerSegments: nonEmptySpeakerSegments,
			displaySections: fallbackDisplaySections
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
				spokenInstruction: spokenInstruction,
				rewritePrompt: state.rewritePromptForRefinement
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
		state.rewritePromptForRefinement = nil
	state.activeRecordingHotkey = nil
	state.activeMinimumKeyTime = nil
	state.activeRecordingSource = nil
	state.isAgentHandoffRequestedForActiveRecording = false

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
			timestampedSections: [TimestampedTranscriptSection]? = nil,
			speakerSegments: [SpeakerAttributedSegment]? = nil,
			screenshotData: Data? = nil,
			screenshotRecognizedText: String? = nil,
			processingErrors: [TranscriptProcessingError]? = nil,
			wasRefined: Bool? = nil,
			outputGenerationDuration: TimeInterval? = nil,
			screenAwareInputSource: ScreenAwareInputSource? = nil,
			historyCheckpointID: UUID? = nil
	) -> Effect<Action> {
		.run { send in
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
				timestampedSections: timestampedSections,
				speakerSegments: speakerSegments,
					screenshotData: screenshotData,
					screenshotRecognizedText: screenshotRecognizedText,
					processingErrors: processingErrors,
					wasRefined: wasRefined,
					outputGenerationDuration: outputGenerationDuration,
					screenAwareInputSource: screenAwareInputSource,
					historyCheckpointID: historyCheckpointID
			)
			await send(.pasteCompletedTranscript(result))
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
		state.rewritePromptForRefinement = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
		state.isAgentHandoffRequestedForActiveRecording = false
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

  /// Move file to permanent location and create a transcript record.
  /// Storage failures are logged but do not block result delivery — the transcription succeeded
  /// from the user's perspective and they should still receive their text.
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
			timestampedSections: [TimestampedTranscriptSection]? = nil,
			speakerSegments: [SpeakerAttributedSegment]? = nil,
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
			checkpoint.timestampedSections = timestampedSections ?? checkpoint.timestampedSections
			checkpoint.speakerSegments = speakerSegments ?? checkpoint.speakerSegments
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
			  timestampedSections: timestampedSections,
			  speakerSegments: speakerSegments,
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
	timestampedSections: [TimestampedTranscriptSection]? = nil,
	speakerSegments: [SpeakerAttributedSegment]? = nil,
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
		timestampedSections: timestampedSections,
		speakerSegments: speakerSegments,
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
	state.isLongRecordingCancellationConfirmationPresented = false
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
		state.rewritePromptForRefinement = nil
		state.activeRecordingHotkey = nil
		state.activeMinimumKeyTime = nil
		state.activeRecordingSource = nil
		state.isAgentHandoffRequestedForActiveRecording = false
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
	let includeSystemAudio = state.activeSystemAudioEnabled
	let systemAudioStartOffset = state.activeSystemAudioStartOffset
	state.activeSystemAudioEnabled = false
	state.activeSystemAudioStartOffset = 0

    return .merge(
      .cancel(id: CancelID.transcription),
				.cancel(id: CancelID.pendingPressAndHold),
				.cancel(id: CancelID.terminalRefinementHold),
				.cancel(id: CancelID.postHocRefinement),
				.cancel(id: CancelID.selectedTextOnlyRefinement),
				.cancel(id: CancelID.selectedTextRefinement),
				.cancel(id: CancelID.screenContextCapture),
      .cancel(id: CancelID.recordingStart),
	  .run { [sleepManagement, systemAudioCapture] _ in
		await selectedText?.cancel()
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        soundEffect.play(.cancel)
		let systemAudioStopResult = includeSystemAudio
			? await systemAudioCapture.stopCapture()
			: .ignored(.noActiveCapture)
		if case let .captured(systemAudioURL, systemAudioDuration) = systemAudioStopResult {
			if let historyCheckpointID {
				transcriptionHistory.withLock { history in
					guard let index = history.history.firstIndex(where: { $0.id == historyCheckpointID }) else { return }
					var channels = history.history[index].audioChannels ?? []
					channels.removeAll { $0.source == .systemAudio }
					channels.append(.init(
						source: .systemAudio,
						audioPath: systemAudioURL,
						duration: systemAudioDuration,
						startOffset: systemAudioStartOffset
					))
					history.history[index].audioChannels = channels
				}
			} else {
				FileManager.default.removeItemIfExists(at: systemAudioURL)
			}
		}

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
	let includeSystemAudio = state.activeSystemAudioEnabled
	state.isRecording = false
	state.isLongRecordingCancellationConfirmationPresented = false
	deactivateScreenAwareMode(&state)
	state.pendingPressAndHoldActivationID = nil
	state.pendingTerminalRefinementID = nil
		state.postHocRefinement = nil
		state.outputGenerationStartTime = nil
    state.isPrewarming = false
	state.isCapturingSelectedTextForRefinement = false
	state.refinedHotKeyReleasedWhileCapturingSelection = false
	state.forcedRefinementMode = nil
	state.rewritePromptForRefinement = nil
	state.activeRecordingHotkey = nil
	state.activeMinimumKeyTime = nil
	state.activeRecordingSource = nil
	state.isAgentHandoffRequestedForActiveRecording = false
	state.activeSystemAudioEnabled = false
	state.activeSystemAudioStartOffset = 0
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
	  .run { [sleepManagement, systemAudioCapture] _ in
		await selectedText?.cancel()
        // Allow system to sleep again
        await sleepManagement.allowSleep()
		if includeSystemAudio, case let .captured(systemAudioURL, _) = await systemAudioCapture.stopCapture() {
			FileManager.default.removeItemIfExists(at: systemAudioURL)
		}
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
	  return .refining(store.rewritePromptForRefinement?.name)
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
		.alert("Cancel long recording?", isPresented: Binding(
			get: { store.isLongRecordingCancellationConfirmationPresented },
			set: { if !$0 { store.send(.dismissLongRecordingCancellationConfirmation) } }
		)) {
			Button("Keep Recording", role: .cancel) {
				store.send(.dismissLongRecordingCancellationConfirmation)
			}
			Button("Cancel Recording", role: .destructive) {
				store.send(.confirmLongRecordingCancellation)
			}
		} message: {
			Text("This recording has been running for a while. Cancelling will stop it without transcribing it.")
		}
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
