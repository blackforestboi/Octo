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
			Text("The configured language model recognizes genuine introductions; saved profiles keep local voice embeddings and one local audio sample.")
		}
		.enableInjection()
	}
}
