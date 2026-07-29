import Dependencies
import DependenciesMacros
import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio
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
	var analyze: @Sendable (URL, SpeakerDiarizationProvider) async throws -> SpeakerDiarizationOutput
}

extension SpeakerDiarizationClient: DependencyKey {
	static var liveValue: Self {
		Self(
			analyze: { audioURL, provider in
				switch provider {
				case .fluidAudio:
					try await fluidAudioDiarization(audioURL)
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

private func fluidAudioDiarization(_ audioURL: URL) async throws -> SpeakerDiarizationOutput {
	#if canImport(FluidAudio)
	let startedAt = Date()
	let manager = OfflineDiarizerManager()
	try await manager.prepareModels()
	let result = try await manager.process(audioURL)
	speakerDiarizationLogger.info(
		"Speaker diarization finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s segments=\(result.segments.count)"
	)
	return .init(segments: result.segments.map {
		.init(
			speakerID: $0.speakerId,
			embedding: $0.embedding,
			startTime: TimeInterval($0.startTimeSeconds),
			endTime: TimeInterval($0.endTimeSeconds),
			qualityScore: $0.qualityScore
		)
	})
	#else
	throw SpeakerDiarizationClientError.unsupportedProvider(.fluidAudio)
	#endif
}
