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
    case about
		case support
  }

	@ObservableState
	struct State: Equatable {
		var transcription: TranscriptionFeature.State = .init()
		var settings: SettingsFeature.State = .init()
		var history: HistoryFeature.State = .init()
		var activeTab: ActiveTab = .settings
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
    case task
    case pasteLastTranscript
    case interruptedRecordingsRecovered([RecoveredRecording], [RecoveredSystemAudioRecording])

    // Permission actions
    case checkPermissions
    case permissionsUpdated(mic: PermissionStatus, acc: PermissionStatus, input: PermissionStatus, screenRecording: Bool)
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
		guard !recordings.isEmpty || !systemAudioRecordings.isEmpty else { return .none }
        state.history.$transcriptionHistory.withLock { history in
          for recovered in recordings {
            let error = TranscriptProcessingError(
              stage: .audio,
              message: "Octo restarted before this recording was transcribed. The recovered audio is available here."
            )
            if let index = history.history.firstIndex(where: { $0.recoverySessionID == recovered.sessionID }) {
              history.history[index].audioPath = recovered.audioURL
              history.history[index].duration = recovered.duration
              history.history[index].status = .failed
              history.history[index].processingErrors = [error]
			  var channels = history.history[index].audioChannels ?? []
			  channels.removeAll { $0.source == .microphone }
			  channels.insert(.init(source: .microphone, audioPath: recovered.audioURL, duration: recovered.duration), at: 0)
			  history.history[index].audioChannels = channels
            } else if history.history.contains(where: { $0.audioPath == recovered.audioURL }) {
              // The final WAV may have been checkpointed just before a crash but its raw
              // source had not been released yet. It is already represented in History.
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
				var channels = history.history[index].audioChannels ?? [
					.init(
						source: .microphone,
						audioPath: history.history[index].audioPath,
						duration: history.history[index].duration
					)
				]
				channels.removeAll { $0.source == .systemAudio }
				channels.append(.init(
					source: .systemAudio,
					audioPath: recovered.audioURL,
					duration: recovered.duration,
					startOffset: max(0, recovered.createdAt.timeIntervalSince(history.history[index].timestamp))
				))
				history.history[index].audioChannels = channels
				history.history[index].status = .failed
				var errors = history.history[index].processingErrors ?? []
				if !errors.contains(where: { $0.stage == .audio && $0.message == interruptionMessage }) {
					errors.append(.init(stage: .audio, message: interruptionMessage))
				}
				history.history[index].processingErrors = errors
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
        }
        return .run { [recording] _ in
          for recovered in recordings {
            await recording.releaseRecordingSource(recovered.audioURL)
          }
        }

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

      case .transcription:
        return .none

      case .settings(.requestMicrophone):
        return .run { send in
          _ = await permissions.requestMicrophone()
          await send(.checkPermissions)
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

      case .appActivated:
        // App became active - re-check permissions
        return .send(.checkPermissions)

      case .modelStatusEvaluated:
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
        await send(.modelStatusEvaluated(false))
        return
      }
      let isReady = await transcription.isModelDownloaded(selectedModel)
      $modelBootstrapState.withLock { state in
        state.modelIdentifier = selectedModel
        if state.modelDisplayName?.isEmpty ?? true {
          state.modelDisplayName = selectedModel
        }
        state.isModelReady = isReady
        if isReady {
          state.lastError = nil
          state.progress = 1
        } else {
          state.progress = 0
        }
      }
      await send(.modelStatusEvaluated(isReady))
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
    } detail: {
      switch store.state.activeTab {
      case .settings:
        SettingsView(
          store: store.scope(state: \.settings, action: \.settings),
          microphonePermission: store.microphonePermission,
          accessibilityPermission: store.accessibilityPermission,
          inputMonitoringPermission: store.inputMonitoringPermission
        )
        .navigationTitle("Settings")
		case .speakers:
			SpeakersView()
				.navigationTitle("Speakers")
      case .handoffs:
        HandoffsView()
          .navigationTitle("Handoffs")
      case .remappings:
        WordRemappingsView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Transforms")
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
			case .support:
				SupportView()
					.navigationTitle("Support")
      }
    }
    .enableInjection()
  }
}
