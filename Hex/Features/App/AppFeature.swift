//
//  AppFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/26/25.
//

import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

@Reducer
struct AppFeature {
	private enum CancelID {
		case modelMissingFlash
		case subscriptionProviderDetection
	}

  enum ActiveTab: Equatable {
    case settings
		case speakers
    case handoffs
    case remappings
    case history
		case session
    case about
		case support
  }

	@ObservableState
	struct State: Equatable {
		var transcription: TranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var history: HistoryFeature.State = .init()
		var activeTab: ActiveTab = .settings
		var isEndRecordingSessionConfirmationPresented = false
		var speakerProfileIDToFocus: UUID?
		@Shared(.hexSettings) var hexSettings: HexSettings
		@Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState

    // Permission state
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var inputMonitoringPermission: PermissionStatus = .notDetermined
    var screenRecordingPermission = false
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case transcription(TranscriptionFeature.Action)
    case settings(SettingsFeature.Action)
    case history(HistoryFeature.Action)
    case setActiveTab(ActiveTab)
		case requestEndRecordingSession
		case cancelEndRecordingSession
		case confirmEndRecordingSession
		case focusSpeakerProfile(UUID)
    case task
    case pasteLastTranscript
    case interruptedRecordingsRecovered([RecoveredRecording], [RecoveredSystemAudioRecording])

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus, screenRecording: Bool)
		case microphonePermissionRequestCompleted(Bool)
		case appActivated
		case modelStatusEvaluated(Bool)
		case preferredSubscriptionProviderDetected(RefinementProvider?)
  }

  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
	@Dependency(\.systemAudioCapture) var systemAudioCapture
  @Dependency(\.permissions) var permissions

  var body: some ReducerOf<Self> {
    BindingReducer()

    Scope(state: \.transcription, action: \.transcription) {
      TranscriptionFeature()
    }

    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Scope(state: \.history, action: \.history) {
      HistoryFeature()
    }

    Reduce { state, action in
      switch action {
      case .binding:
        return .none
        
      case .task:
		let selectedModel = state.hexSettings.selectedModel
		if !selectedModel.isEmpty {
			state.$modelBootstrapState.withLock { bootstrap in
				bootstrap.modelIdentifier = selectedModel
				bootstrap.isModelReady = false
				bootstrap.preparationPhase = .activating
				bootstrap.progress = 0
				bootstrap.lastError = nil
			}
		}
        let startupEffects: [Effect<Action>] = [
          startPasteLastTranscriptMonitoring(),
          ensureSelectedModelReadiness(),
          startPermissionMonitoring(),
		  .run { [recording, systemAudioCapture] send in
			async let microphoneRecordings = recording.recoverInterruptedRecordings()
			async let systemAudioRecordings = systemAudioCapture.recoverInterruptedRecordings()
			await send(.interruptedRecordingsRecovered(
				await microphoneRecordings,
				await systemAudioRecordings
			))
          }
        ]
        guard !state.hexSettings.hasCompletedRefinementProviderDetection,
              state.hexSettings.refinementProvider == .apple
        else {
          return .merge(startupEffects)
        }
        return .merge(
          startupEffects + [
            .run { send in
				let provider = await CLIRefinementClient.preferredAuthenticatedProvider()
				await send(.preferredSubscriptionProviderDetected(
					provider == .codex ? .codexCLI : provider == .claude ? .claudeCLI : nil
				))
            }
            .cancellable(id: CancelID.subscriptionProviderDetection, cancelInFlight: true)
          ]
        )
        
      case .pasteLastTranscript:
        @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
        guard let lastTranscript = state.transcription.recentCompletedTranscript?.text
          ?? transcriptionHistory.latestPasteableTranscriptText else {
          return .none
        }
        return .run { _ in
          await pasteboard.paste(lastTranscript)
        }

      case let .interruptedRecordingsRecovered(recordings, systemAudioRecordings):
		let liveRecoveryIDs = state.history.$transcriptionHistory.withLock { history -> [UUID] in
			var recoveredLiveIDs = Set<UUID>()
          for recovered in recordings {
            let error = TranscriptProcessingError(
              stage: .audio,
              message: "Octo restarted before this recording was transcribed. The recovered audio is available here."
            )
            if let index = history.history.firstIndex(where: { $0.recoverySessionID == recovered.sessionID }) {
			  let shouldDrainLiveTail = history.history[index].liveTranscriptCheckpoint.map {
				[.active, .drainingForPause, .drainingForStop].contains($0.drainState)
			  } ?? false
              history.history[index].audioPath = recovered.audioURL
              history.history[index].duration = recovered.duration
			  history.history[index].status = shouldDrainLiveTail ? .processing : .failed
			  if shouldDrainLiveTail {
				recoveredLiveIDs.insert(history.history[index].id)
			  } else {
				history.history[index].processingErrors = [error]
			  }
			  var channels = history.history[index].audioChannels ?? []
			  if let channelIndex = channels.firstIndex(where: { $0.source == .microphone }) {
				channels[channelIndex].audioPath = recovered.audioURL
				channels[channelIndex].duration = recovered.duration
			  } else {
				channels.insert(.init(source: .microphone, audioPath: recovered.audioURL, duration: recovered.duration), at: 0)
			  }
			  history.history[index].audioChannels = channels
            } else if let index = history.history.firstIndex(where: { $0.audioPath == recovered.audioURL }) {
              // The final WAV may have been checkpointed just before a crash but its raw
              // source had not been released yet. It is already represented in History.
			  if let drainState = history.history[index].liveTranscriptCheckpoint?.drainState,
				[.active, .drainingForPause, .drainingForStop].contains(drainState)
			  {
				history.history[index].status = .processing
				recoveredLiveIDs.insert(history.history[index].id)
			  }
              continue
            } else {
              history.history.insert(
                Transcript(
                  timestamp: recovered.createdAt,
                  text: "Recovered audio from an interrupted recording.",
                  audioPath: recovered.audioURL,
                  duration: recovered.duration,
                  status: .failed,
				  audioChannels: [
					.init(source: .microphone, audioPath: recovered.audioURL, duration: recovered.duration)
				  ],
                  processingErrors: [error],
                  recoverySessionID: recovered.sessionID
                ),
                at: 0
              )
            }
          }

		  for recovered in systemAudioRecordings {
			let interruptionMessage = "Octo restarted before this system audio was attached to its recording. The recovered audio is available here."
			if history.history.contains(where: { transcript in
				transcript.audioChannels?.contains(where: {
					$0.source == .systemAudio && $0.audioPath == recovered.audioURL
				}) == true
			}) {
				continue
			}

			let matchingIndex = history.history.firstIndex { transcript in
				if transcript.recoverySessionID == recovered.parentRecordingSessionID { return true }
				if RecordingRecoveryStore.sessionID(forFinalAudioURL: transcript.audioPath) == recovered.parentRecordingSessionID {
					return true
				}
				return transcript.audioChannels?.contains(where: {
					$0.source == .microphone
						&& RecordingRecoveryStore.sessionID(forFinalAudioURL: $0.audioPath) == recovered.parentRecordingSessionID
				}) == true
			}
			if let index = matchingIndex {
				let shouldDrainLiveTail = history.history[index].liveTranscriptCheckpoint.map {
					[.active, .drainingForPause, .drainingForStop].contains($0.drainState)
				} ?? false
				var channels = history.history[index].audioChannels ?? [
					.init(
						source: .microphone,
						audioPath: history.history[index].audioPath,
						duration: history.history[index].duration
					)
				]
				let startOffset = max(0, recovered.createdAt.timeIntervalSince(history.history[index].timestamp))
				if let channelIndex = channels.firstIndex(where: { $0.source == .systemAudio }) {
					channels[channelIndex].audioPath = recovered.audioURL
					channels[channelIndex].duration = recovered.duration
					channels[channelIndex].startOffset = startOffset
				} else {
					channels.append(.init(
						source: .systemAudio,
						audioPath: recovered.audioURL,
						duration: recovered.duration,
						startOffset: startOffset,
						liveCheckpoint: history.history[index].liveTranscriptCheckpoint?.sources[.systemAudio]
					))
				}
				history.history[index].audioChannels = channels
				history.history[index].status = shouldDrainLiveTail ? .processing : .failed
				if shouldDrainLiveTail {
					recoveredLiveIDs.insert(history.history[index].id)
				} else {
					var errors = history.history[index].processingErrors ?? []
					if !errors.contains(where: { $0.stage == .audio && $0.message == interruptionMessage }) {
						errors.append(.init(stage: .audio, message: interruptionMessage))
					}
					history.history[index].processingErrors = errors
				}
			} else {
				let error = TranscriptProcessingError(stage: .audio, message: interruptionMessage)
				history.history.insert(
					Transcript(
						timestamp: recovered.createdAt,
						text: "Recovered system audio from an interrupted recording.",
						audioPath: recovered.audioURL,
						duration: recovered.duration,
						status: .failed,
						audioChannels: [
							.init(source: .systemAudio, audioPath: recovered.audioURL, duration: recovered.duration)
						],
						processingErrors: [error],
						recoverySessionID: recovered.parentRecordingSessionID
					),
					at: 0
				)
			}
		  }
			for transcript in history.history {
				guard let drainState = transcript.liveTranscriptCheckpoint?.drainState,
					[.active, .drainingForPause, .drainingForStop].contains(drainState)
				else { continue }
				let channels = transcript.audioChannels ?? [
					.init(source: .microphone, audioPath: transcript.audioPath, duration: transcript.duration)
				]
				if channels.contains(where: { FileManager.default.fileExists(atPath: $0.audioPath.path) }) {
					recoveredLiveIDs.insert(transcript.id)
				}
			}
			return Array(recoveredLiveIDs)
        }
		return .merge(
			.run { [recording] _ in
				for recovered in recordings {
					await recording.releaseRecordingSource(recovered.audioURL)
				}
			},
			liveRecoveryIDs.isEmpty
				? .none
				: .send(.transcription(.recoverLiveTranscriptTails(liveRecoveryIDs)))
		)

      case let .preferredSubscriptionProviderDetected(provider):
        guard !state.hexSettings.hasCompletedRefinementProviderDetection else {
          return .none
        }
        state.$hexSettings.withLock { settings in
          settings.hasCompletedRefinementProviderDetection = true
          guard settings.refinementProvider == .apple, let provider else { return }
			settings.refinementProvider = provider
        }
        return .none
        
      case .transcription(.modelMissing):
        HexLog.app.notice("Model missing - activating app and switching to settings")
        state.activeTab = .settings
        state.settings.shouldFlashModelSection = true
        return .run { send in
          await MainActor.run {
            HexLog.app.notice("Activating app for model missing")
            NotificationCenter.default.post(name: .presentSettingsWindow, object: nil)
          }
          try? await Task.sleep(for: .seconds(2))
          await send(.settings(.set(\.shouldFlashModelSection, false)))
        }
		.cancellable(id: CancelID.modelMissingFlash, cancelInFlight: true)

		case .transcription(.recordingSessionOpened):
			state.activeTab = .session
			return .run { _ in
				await MainActor.run {
					NotificationCenter.default.post(name: .presentHistoryWindow, object: nil)
				}
			}

      case .transcription:
        return .none

      case .settings(.requestMicrophone):
		guard state.microphonePermission != .granted else { return .none }
        return .run { send in
		  let granted = await permissions.requestMicrophone()
		  await send(.microphonePermissionRequestCompleted(granted))
        }

      case .settings(.requestAccessibility):
        return .run { send in
          await permissions.requestAccessibility()
          // Poll for status change (macOS doesn't provide callback)
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .settings(.requestInputMonitoring):
        return .run { send in
          _ = await permissions.requestInputMonitoring()
          for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            await send(.checkPermissions)
          }
        }

      case .settings(.requestScreenRecording):
        return .run { send in
          let granted = await permissions.requestScreenRecording()
          await send(.settings(.screenRecordingPermissionResponse(granted)))
        }

      case .settings(.openScreenRecordingSettings):
        return .run { _ in
          await permissions.openScreenRecordingSettings()
        }

		case let .settings(.refinementProviderChanged(provider)):
			switch provider {
			case .codexCLI, .claudeCLI:
				let cliProvider: CLIRefinementClient.Provider = provider == .codexCLI ? .codex : .claude
				return .run { send in
					if let message = await CLIRefinementClient.authenticationError(for: cliProvider) {
						await send(.transcription(.showError(message)))
					}
				}
			default:
				return .send(.transcription(.dismissError))
			}

      case .settings:
        return .none

      case .history(.navigateToSettings):
        state.activeTab = .settings
        return .none
      case .history:
        return .none
		case let .setActiveTab(tab):
			state.activeTab = tab
			if tab != .speakers {
				state.speakerProfileIDToFocus = nil
			}
			return .none
		case .requestEndRecordingSession:
			guard let session = state.transcription.recordingSession, !session.isEnded else {
				state.activeTab = .history
				return .none
			}
			state.isEndRecordingSessionConfirmationPresented = true
			return .none
		case .cancelEndRecordingSession:
			state.isEndRecordingSessionConfirmationPresented = false
			return .none
		case .confirmEndRecordingSession:
			state.isEndRecordingSessionConfirmationPresented = false
			state.activeTab = .history
			return .send(.transcription(.stopRecordingSession))
		case let .focusSpeakerProfile(profileID):
			state.activeTab = .speakers
			state.speakerProfileIDToFocus = profileID
			return .none

      // Permission handling
      case .checkPermissions:
        return .run { send in
          async let mic = permissions.microphoneStatus()
          async let acc = permissions.accessibilityStatus()
          async let input = permissions.inputMonitoringStatus()
          async let screenRecording = permissions.screenRecordingStatus()
          await send(.permissionsUpdated(mic: mic, acc: acc, input: input, screenRecording: screenRecording))
        }

      case let .permissionsUpdated(mic, acc, input, screenRecording):
        state.microphonePermission = mic
        state.accessibilityPermission = acc
        state.inputMonitoringPermission = input
        state.screenRecordingPermission = screenRecording
        if screenRecording {
          state.settings.needsScreenRecordingPermission = false
        } else if state.hexSettings.screenAwareDictationEnabled {
          state.$hexSettings.withLock { $0.screenAwareDictationEnabled = false }
          state.settings.needsScreenRecordingPermission = true
        }
        return .none

	  case let .microphonePermissionRequestCompleted(granted):
		state.microphonePermission = granted ? .granted : .denied
		guard granted else { return .send(.checkPermissions) }
		return .run { send in
			await recording.warmUpRecorder()
			await send(.checkPermissions)
		}

      case .appActivated:
        // App became active - re-check permissions
        return .send(.checkPermissions)

      case let .modelStatusEvaluated(isReady):
        let selectedModel = state.hexSettings.selectedModel
        state.$modelBootstrapState.withLock { bootstrap in
          // `ensureSelectedModelReadiness` completes off the reducer, then
          // sends this action. Mirror that result through the store so the
          // hotkey sees the model that was successfully activated.
          guard bootstrap.modelIdentifier == selectedModel else { return }
          bootstrap.isModelReady = isReady
          if isReady {
            bootstrap.preparationPhase = nil
            bootstrap.progress = 1
            bootstrap.lastError = nil
          }
        }
        return .none
      }
    }
  }
  
  private func startPasteLastTranscriptMonitoring() -> Effect<Action> {
    .run { send in
      @Shared(.isSettingPasteLastTranscriptHotkey) var isSettingPasteLastTranscriptHotkey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      let token = keyEventMonitor.handleKeyEvent { keyEvent in
        // Skip if user is setting a hotkey
        if isSettingPasteLastTranscriptHotkey {
          return false
        }

        // Check if this matches the paste last transcript hotkey
        guard let pasteHotkey = hexSettings.pasteLastTranscriptHotkey,
              let key = keyEvent.key,
              key == pasteHotkey.key,
              keyEvent.modifiers.matchesExactly(pasteHotkey.modifiers) else {
          return false
        }

        // Trigger paste action - use MainActor to avoid escaping send
        MainActor.assumeIsolated {
          send(.pasteLastTranscript)
        }
        return true // Intercept the key event
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

  private func ensureSelectedModelReadiness() -> Effect<Action> {
    .run { send in
      @Shared(.hexSettings) var hexSettings: HexSettings
      @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
      let selectedModel = hexSettings.selectedModel
      guard !selectedModel.isEmpty else {
		$modelBootstrapState.withLock { state in
			state.isModelReady = false
			state.preparationPhase = nil
			state.progress = 0
		}
        await send(.modelStatusEvaluated(false))
        return
      }
		$modelBootstrapState.withLock { state in
			state.modelIdentifier = selectedModel
			if state.modelDisplayName?.isEmpty ?? true {
				state.modelDisplayName = selectedModel
			}
			state.isModelReady = false
			state.preparationPhase = .activating
			state.progress = 0
			state.lastError = nil
		}

		guard await transcription.isModelDownloaded(selectedModel) else {
			$modelBootstrapState.withLock { state in
				guard state.modelIdentifier == selectedModel else { return }
				state.isModelReady = false
				state.preparationPhase = nil
				state.progress = 0
			}
			await send(.modelStatusEvaluated(false))
			return
		}

		do {
			try await transcription.prepareModel(selectedModel) { update in
				$modelBootstrapState.withLock { state in
					guard state.modelIdentifier == selectedModel else { return }
					state.isModelReady = false
					state.preparationPhase = update.phase
					state.progress = update.progress
				}
			}
			$modelBootstrapState.withLock { state in
				guard state.modelIdentifier == selectedModel else { return }
				state.isModelReady = true
				state.preparationPhase = nil
				state.progress = 1
				state.lastError = nil
			}
			await send(.modelStatusEvaluated(true))
		} catch {
			$modelBootstrapState.withLock { state in
				guard state.modelIdentifier == selectedModel else { return }
				state.isModelReady = false
				state.preparationPhase = nil
				state.progress = 0
				state.lastError = error.localizedDescription
			}
			await send(.modelStatusEvaluated(false))
		}
    }
  }

  private func startPermissionMonitoring() -> Effect<Action> {
    .run { send in
      // Initial check on app launch
      await send(.checkPermissions)

      // Monitor app activation events
      for await activation in permissions.observeAppActivation() {
        if case .didBecomeActive = activation {
          await send(.appActivated)
        }
      }

    }
  }

}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $store.activeTab) {
		Button {
			store.send(.setActiveTab(.session))
		} label: {
			if let session = store.transcription.recordingSession,
				store.transcription.hasActiveRecordingSession
			{
				SessionSidebarLabel(session: session)
			} else {
				Label("New Session", systemImage: "waveform")
			}
		}
		.buttonStyle(.plain)
		.tag(AppFeature.ActiveTab.session)

        Button {
          store.send(.setActiveTab(.history))
        } label: {
          Label("History", systemImage: "clock")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.history)

		Button {
			store.send(.setActiveTab(.speakers))
		} label: {
			Label("Speakers", systemImage: "person.2")
		}
		.buttonStyle(.plain)
		.tag(AppFeature.ActiveTab.speakers)

        Button {
          store.send(.setActiveTab(.handoffs))
        } label: {
          Label("Handoffs", systemImage: "arrowshape.turn.up.right")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.handoffs)

        Button {
          store.send(.setActiveTab(.settings))
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.settings)

        Button {
          store.send(.setActiveTab(.remappings))
        } label: {
          Label("Transforms", systemImage: "text.badge.plus")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.remappings)

        Button {
          store.send(.setActiveTab(.about))
        } label: {
          Label("About", systemImage: "info.circle")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.about)

			Button {
				store.send(.setActiveTab(.support))
			} label: {
				Label("Support", systemImage: "questionmark.circle")
			}
			.buttonStyle(.plain)
			.tag(AppFeature.ActiveTab.support)
      }
		.navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
    } detail: {
      switch store.state.activeTab {
      case .settings:
        SettingsView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission,
          accessibilityPermission: store.accessibilityPermission
        )
        .navigationTitle("Settings")
		case .speakers:
			SpeakersView(profileIDToFocus: store.speakerProfileIDToFocus)
				.navigationTitle("Speakers")
      case .handoffs:
        HandoffsView()
          .navigationTitle("Handoffs")
      case .remappings:
        WordRemappingsView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Transforms")
      case .history:
		HistoryView(
			store: store.scope(state: \.history, action: \.history),
			onOpenSpeaker: { store.send(.focusSpeakerProfile($0)) }
		)
		  .navigationTitle("History")
		case .session:
			if let session = store.transcription.recordingSession, !session.isEnded {
				RecordingSessionView(
					session: session,
					takes: store.history.transcriptionHistory.history.filter { $0.recordingSessionID == session.id },
					rewritePrompts: store.hexSettings.rewritePrompts,
					meter: store.transcription.meter,
					systemAudioMeter: store.transcription.systemAudioMeter,
					isTranscribing: store.transcription.isTranscribing,
					send: { store.send(.transcription($0)) },
					onBack: { store.send(.requestEndRecordingSession) }
				)
				.navigationTitle(session.title)
			} else {
				NewRecordingSessionView {
					store.send(.transcription(.startRecordingSession))
				}
				.navigationTitle("New Session")
			}
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
			case .support:
				SupportView()
					.navigationTitle("Support")
      }
    }
    .enableInjection()
		.alert(
			"End Session",
			isPresented: Binding(
				get: { store.isEndRecordingSessionConfirmationPresented },
				set: { if !$0 { store.send(.cancelEndRecordingSession) } }
			)
		) {
			Button("End Session", role: .destructive) {
				store.send(.confirmEndRecordingSession)
			}
			Button("Cancel", role: .cancel) {
				store.send(.cancelEndRecordingSession)
			}
		} message: {
			Text("Your session will be available via the history.")
		}
  }
}

private struct NewRecordingSessionView: View {
	let onRecord: () -> Void

	var body: some View {
		VStack(spacing: 16) {
			Image(systemName: "waveform")
				.font(.system(size: 36, weight: .medium))
				.foregroundStyle(.secondary)
			Text("New Session")
				.font(.title2.weight(.semibold))
			Text("Press Record when you’re ready to begin.")
				.foregroundStyle(.secondary)
			Button(action: onRecord) {
				Label("Record", systemImage: "record.circle")
					.frame(minWidth: 90)
			}
			.buttonStyle(.borderedProminent)
			.tint(.red)
			.controlSize(.large)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(40)
	}
}

struct RecordingSessionTitlebarControls: View {
	@Bindable var store: StoreOf<AppFeature>

	var body: some View {
		if store.activeTab == .session,
			store.transcription.hasActiveRecordingSession,
			let session = store.transcription.recordingSession
		{
			HStack(spacing: 14) {
				captureToggle(
					"Live Transcript",
					isOn: Binding(
						get: { store.transcription.recordingSession?.liveTranscriptionEnabled ?? false },
						set: { store.send(.transcription(.recordingSessionLiveTranscriptionChanged($0))) }
					)
				)
				.disabled(session.phase != .paused)
				captureToggle(
					"Speaker ID",
					isOn: Binding(
						get: { store.transcription.recordingSession?.speakerIdentificationEnabled ?? false },
						set: { store.send(.transcription(.recordingSessionSpeakerIdentificationChanged($0))) }
					)
				)
				.disabled(session.isRecording || session.isDraining || session.isEnded || session.phase == .preparing)
				captureToggle(
					"System Audio",
					isOn: Binding(
						get: { store.transcription.recordingSession?.systemAudioEnabled ?? false },
						set: { store.send(.transcription(.recordingSessionSystemAudioChanged($0))) }
					)
				)
				.disabled(session.isRecording || session.isDraining || session.isEnded || session.phase == .preparing)

				if session.speakerIdentificationEnabled {
					Picker("Speaker mode", selection: Binding(
						get: { store.transcription.recordingSession?.speakerMode ?? .highAccuracyFour },
						set: { store.send(.transcription(.recordingSessionSpeakerModeChanged($0))) }
					)) {
						ForEach(SpeakerDiarizationMode.allCases) { mode in
							Text("\(mode.displayName) · \(mode.detail)").tag(mode)
						}
					}
					.pickerStyle(.menu)
					.fixedSize()
					.disabled(session.hasCommittedLiveTranscript || session.isPreparingSpeakerMode || session.isRecording || session.isDraining || session.isEnded || session.phase == .preparing)
				}
			}
			.fixedSize()
			.padding(.trailing, 8)
			.accessibilityElement(children: .contain)
			.accessibilityLabel("Recording options")
		}
	}

	private func captureToggle(_ title: String, isOn: Binding<Bool>) -> some View {
		HStack(spacing: 7) {
			Text(title)
			Toggle("", isOn: isOn)
				.labelsHidden()
				.toggleStyle(.switch)
		}
	}
}

private struct SessionSidebarLabel: View {
	let session: TranscriptionFeature.RecordingSession

	var body: some View {
		TimelineView(.periodic(from: .now, by: 1)) { context in
			HStack(spacing: 10) {
				ZStack(alignment: .bottomTrailing) {
					Image(systemName: "waveform")
					if session.isRecording {
						PulsingSessionDot()
					}
				}
					.frame(width: 22)
				Text("Session")
				Spacer(minLength: 6)
				Text(formattedElapsedTime(session.elapsedDuration(at: context.date)))
					.monospacedDigit()
					.foregroundStyle(.secondary)
			}
		}
		.accessibilityElement(children: .combine)
		.accessibilityLabel("Session")
		.accessibilityValue(session.isRecording ? "Recording" : "Paused")
	}

	private func formattedElapsedTime(_ duration: TimeInterval) -> String {
		let totalSeconds = Int(duration)
		return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
	}
}

private struct PulsingSessionDot: View {
	@State private var isPulsing = false

	var body: some View {
		Circle()
			.fill(.red)
			.frame(width: 8, height: 8)
			.scaleEffect(isPulsing ? 1 : 0.7)
			.shadow(color: .red.opacity(isPulsing ? 0.7 : 0.2), radius: isPulsing ? 5 : 1)
			.onAppear {
				withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
					isPulsing = true
				}
			}
	}
}
