import AVFoundation
import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// A focused view of the local voice library. Profiles are intentionally managed
/// outside the transcription settings so their samples remain easy to review.
struct SpeakersView: View {
	@ObserveInjection var inject
	@Shared(.speakerVoiceLibrary) private var speakerVoiceLibrary: SpeakerVoiceLibrary
	let profileIDToFocus: UUID?

	init(profileIDToFocus: UUID? = nil) {
		self.profileIDToFocus = profileIDToFocus
	}

	var body: some View {
		Group {
			if profiles.isEmpty {
				ContentUnavailableView(
					"No speakers yet",
					systemImage: "person.2",
					description: Text("Turn on speaker identification, then have each person say their name during a recording.")
				)
			} else {
				ScrollViewReader { proxy in
					ScrollView(.vertical, showsIndicators: true) {
						LazyVStack(alignment: .leading, spacing: 14) {
							ForEach(profiles) { profile in
								SpeakerProfileCard(
									profile: profile,
									shouldFocusName: profile.id == profileIDToFocus
								)
								.id(profile.id)
							}
						}
						.frame(width: 760, alignment: .leading)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(20)
					}
					.task(id: profileIDToFocus) {
						guard let profileIDToFocus else { return }
						await Task.yield()
						withAnimation {
							proxy.scrollTo(profileIDToFocus, anchor: .center)
						}
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			}
		}
		.enableInjection()
	}

	private var profiles: [SpeakerVoiceProfile] {
		speakerVoiceLibrary.profiles.sorted {
			$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
	}
}

private struct SpeakerProfileCard: View {
	let profile: SpeakerVoiceProfile
	let shouldFocusName: Bool
	@Shared(.speakerVoiceLibrary) private var speakerVoiceLibrary: SpeakerVoiceLibrary
	@State private var draftName: String
	@FocusState private var isEditingName: Bool
	@State private var audioPlayer: AVAudioPlayer?
	@State private var playingSampleID: UUID?

	init(
		profile: SpeakerVoiceProfile,
		shouldFocusName: Bool = false
	) {
		self.profile = profile
		self.shouldFocusName = shouldFocusName
		_draftName = State(initialValue: profile.name)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: "person.crop.circle.fill")
					.font(.system(size: 30))
					.foregroundStyle(.tint)

				VStack(alignment: .leading, spacing: 3) {
					Text(profile.name)
						.font(.headline)
					Text("Last matched \(profile.lastSeenAt, style: .relative)")
						.settingsCaption()
				}

				Spacer()

				Button(role: .destructive, action: deleteProfile) {
					Label("Delete speaker", systemImage: "trash")
				}
				.buttonStyle(.borderless)
			}

			HStack(spacing: 8) {
				TextField("Speaker name", text: $draftName)
					.textFieldStyle(.roundedBorder)
					.focused($isEditingName)
					.onSubmit(saveName)

				Button("Save", action: saveName)
					.disabled(trimmedDraftName.isEmpty || trimmedDraftName == profile.name)
			}

			VStack(alignment: .leading, spacing: 8) {
				Text("Audio sample")
					.font(.subheadline.weight(.semibold))

				if audioSamples.isEmpty {
					Text("Speaker matching uses this profile’s local voiceprint. A playable clip is saved the next time it is matched.")
						.settingsCaption()
				} else {
					ForEach(audioSamples) { sample in
						HStack(spacing: 10) {
							Button(action: { togglePlayback(sample) }) {
								Label(
									playingSampleID == sample.id && audioPlayer?.isPlaying == true ? "Pause audio" : "Play audio",
									systemImage: playingSampleID == sample.id && audioPlayer?.isPlaying == true ? "pause.fill" : "play.fill"
								)
							}
							.buttonStyle(.bordered)
							.controlSize(.small)

							Text(sample.duration, format: .number.precision(.fractionLength(1)))
								.font(.caption.monospacedDigit())
								.foregroundStyle(.secondary)
							Text("seconds")
								.settingsCaption()
							Spacer()
						}
						.padding(.horizontal, 10)
						.padding(.vertical, 8)
						.background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
					}
				}
			}
		}
		.padding(18)
		.background(Color.octoCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
		.onChange(of: profile.name) { _, newName in
			guard !isEditingName else { return }
			draftName = newName
		}
		.task(id: shouldFocusName) {
			guard shouldFocusName else { return }
			await Task.yield()
			isEditingName = true
		}
		.onDisappear {
			audioPlayer?.stop()
		}
	}

	private var audioSamples: [SpeakerVoiceSample] {
		Array((profile.audioSamples ?? []).filter { FileManager.default.fileExists(atPath: $0.audioURL.path) }.prefix(1))
	}

	private var trimmedDraftName: String {
		draftName.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func saveName() {
		guard !trimmedDraftName.isEmpty else { return }
		$speakerVoiceLibrary.withLock { library in
			guard let index = library.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
			library.profiles[index].name = trimmedDraftName
			library.profiles[index].isNameUserEdited = true
		}
		isEditingName = false
	}

	private func deleteProfile() {
		let samples = profile.audioSamples ?? []
		$speakerVoiceLibrary.withLock { library in
			library.profiles.removeAll { $0.id == profile.id }
		}
		SpeakerVoiceSampleStore.delete(samples)
	}

	private func togglePlayback(_ sample: SpeakerVoiceSample) {
		if playingSampleID == sample.id, audioPlayer?.isPlaying == true {
			audioPlayer?.stop()
			playingSampleID = nil
			return
		}

		do {
			let player = try AVAudioPlayer(contentsOf: sample.audioURL)
			player.prepareToPlay()
			player.play()
			audioPlayer = player
			playingSampleID = sample.id
		} catch {
			audioPlayer = nil
			playingSampleID = nil
		}
	}
}
