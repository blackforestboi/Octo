import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

private let speakerDiarizationLogger = HexLog.transcription

enum SpeakerDiarizationClientError: LocalizedError {
	case unsupportedProvider(SpeakerDiarizationProvider)

	var errorDescription: String? {
		switch self {
		case let .unsupportedProvider(provider):
			"The \(provider.displayName) speaker identification engine is unavailable."
		}
	}
}

/// A provider-neutral boundary for the diarization model. `TranscriptionFeature`
/// only receives Octo's stable `SpeakerDiarizationOutput`, so adding or replacing a
/// local model happens here rather than through the UI, history, or ASR pipeline.
@DependencyClient
struct SpeakerDiarizationClient {
	var analyze: @Sendable (URL, SpeakerDiarizationProvider, [SpeakerVoiceProfile]) async throws -> SpeakerDiarizationOutput
}

extension SpeakerDiarizationClient: DependencyKey {
	static var liveValue: Self {
		let fluidAudioEngine = FluidAudioSortformerEngine()
		return Self(
			analyze: { audioURL, provider, profiles in
				switch provider {
				case .fluidAudio:
					try await fluidAudioEngine.analyze(audioURL, profiles: profiles)
				}
			}
		)
	}
}

extension DependencyValues {
	var speakerDiarization: SpeakerDiarizationClient {
		get { self[SpeakerDiarizationClient.self] }
		set { self[SpeakerDiarizationClient.self] = newValue }
	}
}

#if canImport(FluidAudio)
/// Serializes model use and retains the expensive Core ML model between channels.
/// Each analysis gets a fresh diarizer so speaker state never leaks between recordings.
private actor FluidAudioSortformerEngine {
	private static let maximumEnrolledProfiles = 3
	private let config = SortformerConfig.balancedV2_1
	private var models: SortformerModels?

	func analyze(
		_ audioURL: URL,
		profiles: [SpeakerVoiceProfile]
	) async throws -> SpeakerDiarizationOutput {
		let startedAt = Date()
		let loadedModels = try await loadModels()
		let diarizer = SortformerDiarizer(config: config)
		diarizer.initialize(models: loadedModels)

		let enrollments = enrollmentCandidates(from: profiles)
		var profileIDBySpeakerIndex = [Int: UUID]()
		let converter = AudioConverter(sampleRate: Double(config.sampleRate))
		for enrollment in enrollments.selected {
			do {
				let samples = try converter.resampleAudioFile(enrollment.sample.audioURL)
				guard let speaker = try diarizer.enrollSpeaker(
					withAudio: samples,
					named: enrollment.profile.id.uuidString,
					overwritingAssignedSpeakerName: false
				) else {
					speakerDiarizationLogger.warning(
						"Speaker enrollment rejected profile=\(enrollment.profile.id.uuidString, privacy: .public) sampleDuration=\(String(format: "%.2f", enrollment.sample.duration), privacy: .public)"
					)
					continue
				}
				profileIDBySpeakerIndex[speaker.index] = enrollment.profile.id
				speakerDiarizationLogger.notice(
					"Speaker enrollment accepted profile=\(enrollment.profile.id.uuidString, privacy: .public) slot=\(speaker.index) sampleDuration=\(String(format: "%.2f", enrollment.sample.duration), privacy: .public) profileUpdated=false"
				)
			} catch {
				speakerDiarizationLogger.warning(
					"Speaker enrollment failed profile=\(enrollment.profile.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
				)
			}
		}
		for profile in enrollments.withoutUsableSamples {
			speakerDiarizationLogger.info(
				"Speaker enrollment skipped profile=\(profile.id.uuidString, privacy: .public) reason=noUsableImmutableSample"
			)
		}
		for profile in enrollments.overCapacity {
			speakerDiarizationLogger.info(
				"Speaker enrollment skipped profile=\(profile.id.uuidString, privacy: .public) reason=reservedUnknownSpeakerSlot"
			)
		}

		let timeline = try diarizer.processComplete(
			audioFileURL: audioURL,
			keepingEnrolledSpeakers: true
		)
		let segments = timeline.speakers.values
			.flatMap { speaker in
				(speaker.finalizedSegments + speaker.tentativeSegments).map { segment in
					SpeakerDiarizationSegment(
						speakerID: "sortformer-\(segment.speakerIndex)",
						embedding: [],
						startTime: TimeInterval(segment.startTime),
						endTime: TimeInterval(segment.endTime),
						qualityScore: segment.activity.isFinite ? segment.activity : 0,
						profileID: profileIDBySpeakerIndex[segment.speakerIndex]
					)
				}
			}
			.sorted {
				if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
				return $0.speakerID < $1.speakerID
			}

		speakerDiarizationLogger.notice(
			"Speaker diarization finished mode=sortformerBalancedV2_1 elapsedSeconds=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)), privacy: .public) segments=\(segments.count) speakers=\(Set(segments.map(\.speakerID)).count) enrolledProfiles=\(profileIDBySpeakerIndex.count) profileUpdates=0"
		)
		return .init(segments: segments)
	}

	private func loadModels() async throws -> SortformerModels {
		if let models { return models }
		let startedAt = Date()
		let loaded = try await SortformerModels.loadFromHuggingFace(config: config)
		models = loaded
		speakerDiarizationLogger.notice(
			"Speaker diarization model loaded mode=sortformerBalancedV2_1 elapsedSeconds=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)), privacy: .public)"
		)
		return loaded
	}

	private func enrollmentCandidates(from profiles: [SpeakerVoiceProfile]) -> (
		selected: [(profile: SpeakerVoiceProfile, sample: SpeakerVoiceSample)],
		withoutUsableSamples: [SpeakerVoiceProfile],
		overCapacity: [SpeakerVoiceProfile]
	) {
		var usable = [(profile: SpeakerVoiceProfile, sample: SpeakerVoiceSample)]()
		var withoutUsableSamples = [SpeakerVoiceProfile]()
		for profile in profiles {
			guard let sample = (profile.audioSamples ?? []).first(where: {
				$0.duration >= SpeakerVoiceSampleStore.minimumEnrollmentDuration
					&& FileManager.default.fileExists(atPath: $0.audioURL.path)
			}) else {
				withoutUsableSamples.append(profile)
				continue
			}
			usable.append((profile, sample))
		}
		usable.sort {
			if $0.profile.lastSeenAt != $1.profile.lastSeenAt {
				return $0.profile.lastSeenAt > $1.profile.lastSeenAt
			}
			return $0.profile.createdAt > $1.profile.createdAt
		}
		let selected = Array(usable.prefix(Self.maximumEnrolledProfiles))
		let overCapacity = usable.dropFirst(Self.maximumEnrolledProfiles).map(\.profile)
		return (selected, withoutUsableSamples, overCapacity)
	}
}
#else
private actor FluidAudioSortformerEngine {
	func analyze(
		_ audioURL: URL,
		profiles: [SpeakerVoiceProfile]
	) async throws -> SpeakerDiarizationOutput {
		_ = audioURL
		_ = profiles
		throw SpeakerDiarizationClientError.unsupportedProvider(.fluidAudio)
	}
}
#endif
