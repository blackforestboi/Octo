import AVFoundation
import Foundation
import HexCore

/// Creates small, durable clips for the local speaker library. Samples are copied
/// out of History so a profile remains audible when its originating recording is pruned.
enum SpeakerVoiceSampleStore {
	static let maximumSampleDuration: TimeInterval = 12
	static let minimumSampleDuration: TimeInterval = 0.25
	static let leadingBoundaryPaddingDuration: TimeInterval = 0.5
	static let trailingBoundaryPaddingDuration: TimeInterval = 0.25
	static let currentExtractionVersion = 1
	static let comparisonSilenceDuration: TimeInterval = 0.75

	struct SampleRange: Equatable {
		let startTime: TimeInterval
		let duration: TimeInterval

		var endTime: TimeInterval { startTime + duration }
	}

	/// Word timestamps describe recognized tokens, not the full acoustic envelope.
	/// Preserve a small amount around them so plosives and trailing phonemes are not clipped.
	static func sampleRange(
		sourceDuration: TimeInterval,
		startTime: TimeInterval,
		endTime: TimeInterval
	) -> SampleRange? {
		guard sourceDuration.isFinite,
			startTime.isFinite,
			endTime.isFinite,
			sourceDuration > 0,
			endTime > startTime
		else { return nil }

		let recognizedStart = min(max(0, startTime), sourceDuration)
		let recognizedEnd = min(max(recognizedStart, endTime), sourceDuration)
		let recognizedDuration = recognizedEnd - recognizedStart
		guard recognizedDuration > 0 else { return nil }

		if recognizedDuration >= maximumSampleDuration {
			return .init(startTime: recognizedStart, duration: maximumSampleDuration)
		}

		var leadingPadding = min(leadingBoundaryPaddingDuration, recognizedStart)
		var trailingPadding = min(trailingBoundaryPaddingDuration, sourceDuration - recognizedEnd)
		let availablePadding = maximumSampleDuration - recognizedDuration
		let requestedPadding = leadingPadding + trailingPadding
		if requestedPadding > availablePadding {
			let scale = availablePadding / requestedPadding
			leadingPadding *= scale
			trailingPadding *= scale
		}

		let duration = recognizedDuration + leadingPadding + trailingPadding
		guard duration >= minimumSampleDuration else { return nil }
		return .init(startTime: recognizedStart - leadingPadding, duration: duration)
	}

	static func capture(
		from sourceURL: URL,
		profileID: UUID,
		startTime: TimeInterval,
		endTime: TimeInterval
	) async throws -> SpeakerVoiceSample? {
		let asset = AVURLAsset(url: sourceURL)
		let sourceDuration = try await asset.load(.duration).seconds
		guard let range = sampleRange(
			sourceDuration: sourceDuration,
			startTime: startTime,
			endTime: endTime
		) else { return nil }

		guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A),
			exporter.supportedFileTypes.contains(.m4a)
		else {
			throw SpeakerVoiceSampleStoreError.unsupportedAudio
		}

		let directory = try samplesDirectory()
		let destinationURL = directory
			.appendingPathComponent("\(profileID.uuidString)-\(UUID().uuidString).m4a")
		exporter.timeRange = CMTimeRange(
			start: CMTime(seconds: range.startTime, preferredTimescale: 600),
			duration: CMTime(seconds: range.duration, preferredTimescale: 600)
		)
		try await export(exporter, to: destinationURL, as: .m4a)

		return .init(
			audioURL: destinationURL,
			duration: range.duration,
			extractionVersion: currentExtractionVersion
		)
	}

	static func delete(_ samples: [SpeakerVoiceSample]) {
		for sample in samples {
			FileManager.default.removeItemIfExists(at: sample.audioURL)
		}
	}

	static func comparisonInput(
		references: [SpeakerVoiceComparisonReference],
		candidateURL: URL,
		candidateStartTime: TimeInterval,
		candidateEndTime: TimeInterval
	) async throws -> SpeakerVoiceComparisonInput? {
		guard !references.isEmpty else { return nil }
		let composition = AVMutableComposition()
		guard let destinationTrack = composition.addMutableTrack(
			withMediaType: .audio,
			preferredTrackID: kCMPersistentTrackID_Invalid
		) else {
			throw SpeakerVoiceSampleStoreError.unsupportedAudio
		}

		var cursor = CMTime.zero
		var ranges = [SpeakerVoiceComparisonRange]()
		for reference in references {
			let asset = AVURLAsset(url: reference.audioURL)
			guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
			let duration = try await asset.load(.duration)
			guard duration.seconds >= 0.25 else { continue }
			try destinationTrack.insertTimeRange(
				CMTimeRange(start: .zero, duration: duration),
				of: sourceTrack,
				at: cursor
			)
			ranges.append(.init(
				profileID: reference.profileID,
				startTime: cursor.seconds,
				endTime: (cursor + duration).seconds
			))
			cursor = cursor + duration + CMTime(seconds: comparisonSilenceDuration, preferredTimescale: 600)
		}

		guard !ranges.isEmpty else { return nil }
		let candidateAsset = AVURLAsset(url: candidateURL)
		guard let candidateTrack = try await candidateAsset.loadTracks(withMediaType: .audio).first else {
			throw SpeakerVoiceSampleStoreError.unsupportedAudio
		}
		let candidateDuration = try await candidateAsset.load(.duration).seconds
		let start = min(max(0, candidateStartTime), candidateDuration)
		let duration = min(maximumSampleDuration, min(candidateEndTime - start, candidateDuration - start))
		guard duration >= minimumSampleDuration else { return nil }
		let candidateRange = CMTimeRange(
			start: CMTime(seconds: start, preferredTimescale: 600),
			duration: CMTime(seconds: duration, preferredTimescale: 600)
		)
		try destinationTrack.insertTimeRange(candidateRange, of: candidateTrack, at: cursor)

		guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A),
			exporter.supportedFileTypes.contains(.m4a)
		else {
			throw SpeakerVoiceSampleStoreError.unsupportedAudio
		}
		let destinationURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("speaker-comparison-\(UUID().uuidString).m4a")
		try await export(exporter, to: destinationURL, as: .m4a)
		return .init(
			audioURL: destinationURL,
			referenceRanges: ranges,
			candidateStartTime: cursor.seconds,
			candidateEndTime: (cursor + candidateRange.duration).seconds
		)
	}

	private static func samplesDirectory() throws -> URL {
		let directory = try URL.hexApplicationSupport
			.appendingPathComponent("SpeakerSamples", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	private static func export(
		_ exporter: AVAssetExportSession,
		to destinationURL: URL,
		as fileType: AVFileType
	) async throws {
		if #available(macOS 15.0, *) {
			try await exporter.export(to: destinationURL, as: fileType)
		} else {
			exporter.outputURL = destinationURL
			exporter.outputFileType = fileType
			try await withCheckedThrowingContinuation { continuation in
				exporter.exportAsynchronously {
					if exporter.status == .completed {
						continuation.resume()
					} else {
						continuation.resume(
							throwing: exporter.error ?? SpeakerVoiceSampleStoreError.unsupportedAudio
						)
					}
				}
			}
		}
	}
}

struct SpeakerVoiceComparisonReference {
	let profileID: UUID
	let audioURL: URL
}

struct SpeakerVoiceComparisonRange {
	let profileID: UUID
	let startTime: TimeInterval
	let endTime: TimeInterval
}

struct SpeakerVoiceComparisonInput {
	let audioURL: URL
	let referenceRanges: [SpeakerVoiceComparisonRange]
	let candidateStartTime: TimeInterval
	let candidateEndTime: TimeInterval
}

private enum SpeakerVoiceSampleStoreError: LocalizedError {
	case unsupportedAudio

	var errorDescription: String? {
		switch self {
		case .unsupportedAudio:
			"Unable to create an audio sample for this speaker."
		}
	}
}
