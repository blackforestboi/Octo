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
    case remappings
    case history
    case about
  }

	@ObservableState
	struct State {
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
    case interruptedRecordingsRecovered([RecoveredRecording])

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
          .run { [recording] send in
            await send(.interruptedRecordingsRecovered(await recording.recoverInterruptedRecordings()))
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

      case let .interruptedRecordingsRecovered(recordings):
        guard !recordings.isEmpty else { return .none }
        state.history.$transcriptionHistory.withLock { history in
          for recovered in recordings where !history.history.contains(where: { $0.recoverySessionID == recovered.sessionID }) {
            history.history.insert(
              Transcript(
                timestamp: recovered.createdAt,
                text: "Recovered audio from an interrupted recording.",
                audioPath: recovered.audioURL,
                duration: recovered.duration,
                status: .failed,
                processingErrors: [
                  .init(
                    stage: .audio,
                    message: "Octo restarted before this recording was transcribed. The recovered audio is available here."
                  )
                ],
                recoverySessionID: recovered.sessionID
              ),
              at: 0
            )
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
          store.send(.setActiveTab(.history))
        } label: {
          Label("History", systemImage: "clock")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.history)

        Button {
          store.send(.setActiveTab(.about))
        } label: {
          Label("About", systemImage: "info.circle")
        }
        .buttonStyle(.plain)
        .tag(AppFeature.ActiveTab.about)
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
      case .remappings:
        WordRemappingsView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("Transforms")
      case .history:
        HistoryView(store: store.scope(state: \.history, action: \.history))
          .navigationTitle("History")
      case .about:
        AboutView(store: store.scope(state: \.settings, action: \.settings))
          .navigationTitle("About")
      }
    }
    .enableInjection()
  }
}
