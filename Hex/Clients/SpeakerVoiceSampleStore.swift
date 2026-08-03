import AVFoundation
import Foundation
import HexCore

/// Creates small, durable clips for the local speaker library. Samples are copied
/// out of History so a profile remains audible when its originating recording is pruned.
enum SpeakerVoiceSampleStore {
	static let maximumSampleDuration: TimeInterval = 12
	/// Sortformer's shortest supported enrollment window is 13 diarization frames.
	static let minimumEnrollmentDuration: TimeInterval = 1.04
	static let minimumSampleDuration = minimumEnrollmentDuration
	static let leadingBoundaryPaddingDuration: TimeInterval = 0.5
	static let trailingBoundaryPaddingDuration: TimeInterval = 0.25
	static let currentExtractionVersion = 2

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
		// Padding a very short turn can pull a neighbouring speaker into the saved
		// reference. Fail closed unless the attributed speech itself is long enough
		// for Sortformer enrollment.
		guard recognizedDuration >= minimumSampleDuration else { return nil }

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

private enum SpeakerVoiceSampleStoreError: LocalizedError {
	case unsupportedAudio

	var errorDescription: String? {
		switch self {
		case .unsupportedAudio:
			"Unable to create an audio sample for this speaker."
		}
	}
}
