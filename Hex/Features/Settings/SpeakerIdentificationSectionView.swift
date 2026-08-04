import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct SpeakerIdentificationSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>

	var body: some View {
		Section {
			Label {
				Toggle(
					"Live transcription in Recording Sessions",
					isOn: Binding(
						get: { store.hexSettings.liveTranscriptionEnabled },
						set: { store.send(.setLiveTranscriptionEnabled($0)) }
					)
				)
				Text("Show only durable, committed text with a short delay. Each session can override this default between takes.")
					.settingsCaption()
			} icon: {
				Image(systemName: "text.bubble.fill")
			}

			Label {
				Toggle(
					"Identify speakers",
					isOn: Binding(
						get: { store.hexSettings.speakerIdentificationEnabled },
						set: { store.send(.setSpeakerIdentificationEnabled($0)) }
					)
				)
				Text("Add local speaker labels after each recording. Transcription stays on-device and continues to use your selected model.")
					.settingsCaption()
			} icon: {
				Image(systemName: "person.2.wave.2")
			}

			if store.hexSettings.speakerIdentificationEnabled {
				Label {
					HStack {
						VStack(alignment: .leading, spacing: 2) {
							Text("Speaker capacity")
							Text(store.hexSettings.speakerDiarizationMode.detail)
								.settingsCaption()
						}
						Spacer()
						Picker("Speaker capacity", selection: Binding(
							get: { store.hexSettings.speakerDiarizationMode },
							set: { store.send(.setSpeakerDiarizationMode($0)) }
						)) {
							ForEach(SpeakerDiarizationMode.allCases) { mode in
								Text("\(mode.displayName) · \(mode.detail)").tag(mode)
							}
						}
						.pickerStyle(.menu)
					}
				} icon: {
					Image(systemName: "person.3.sequence")
				}

				if store.isPreparingSpeakerDiarizationMode {
					Label {
						HStack(spacing: 8) {
							ProgressView()
								.controlSize(.small)
							Text("Preparing the selected speaker model…")
								.settingsCaption()
						}
					} icon: {
						Image(systemName: "arrow.down.circle")
					}
				} else if let error = store.speakerDiarizationModePreparationError {
					Label {
						Text(error)
							.settingsCaption()
							.foregroundStyle(.red)
					} icon: {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.red)
					}
				}

				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text("Automatic names")
							.font(.subheadline.weight(.semibold))
						Text("During the first 20 seconds of a speaker’s turn, introduce yourself naturally. Octo uses the conversation’s context before saving a local voice profile for future recordings.")
							.settingsCaption()
					}
				} icon: {
					Image(systemName: "text.quote")
				}

				Label {
					HStack {
						Text("Diarization engine")
						Spacer()
						Text(store.hexSettings.speakerDiarizationProvider.displayName)
							.foregroundStyle(.secondary)
					}
				} icon: {
					Image(systemName: "cpu")
				}

				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text("Manage speakers")
							.font(.subheadline.weight(.semibold))
						Text("Use the Speakers page in the sidebar to review examples, rename a speaker, or remove a saved voice profile.")
							.settingsCaption()
					}
				} icon: {
					Image(systemName: "person.2")
				}
			}
		} header: {
			Text("Speaker Identification")
		} footer: {
			Text("Recording Sessions are always saved to History so every visible live fragment remains crash-safe. The configured language model recognizes genuine introductions; saved profiles stay local.")
		}
		.enableInjection()
	}
}
