import AVFoundation
import CoreGraphics
import CoreMedia
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
@preconcurrency import ScreenCaptureKit

private let systemAudioCaptureLogger = HexLog.recording

enum SystemAudioCaptureStartResult: Equatable, Sendable {
	case started
	case permissionDenied
	case failed
}

enum SystemAudioCaptureIgnoredStopReason: Equatable, Sendable {
	case noActiveCapture
	case noCapturedAudio
}

enum SystemAudioCaptureStopResult: Equatable, Sendable {
	case captured(URL, TimeInterval)
	case ignored(SystemAudioCaptureIgnoredStopReason)
	case failed(String)
}

@DependencyClient
struct SystemAudioCaptureClient {
	var startCapture: @Sendable () async -> SystemAudioCaptureStartResult = { .failed }
	var stopCapture: @Sendable () async -> SystemAudioCaptureStopResult = { .ignored(.noActiveCapture) }
}

extension SystemAudioCaptureClient: DependencyKey {
	static let liveValue: Self = {
		let live = SystemAudioCaptureClientLive()
		return Self(
			startCapture: { await live.startCapture() },
			stopCapture: { await live.stopCapture() }
		)
	}()
}

extension DependencyValues {
	var systemAudioCapture: SystemAudioCaptureClient {
		get { self[SystemAudioCaptureClient.self] }
		set { self[SystemAudioCaptureClient.self] = newValue }
	}
}

private final class SystemAudioCaptureWriter: NSObject, SCStreamOutput, @unchecked Sendable {
	private let lock = NSLock()
	private let writer: AVAssetWriter
	private let input: AVAssetWriterInput
	private var started = false
	private var startedAt: CMTime?
	private var latestSampleTime: CMTime?

	init(outputURL: URL) throws {
		writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
		input = AVAssetWriterInput(
			mediaType: .audio,
			outputSettings: [
				AVFormatIDKey: kAudioFormatMPEG4AAC,
				AVSampleRateKey: 48_000,
				AVNumberOfChannelsKey: 2,
				AVEncoderBitRateKey: 192_000,
			]
		)
		input.expectsMediaDataInRealTime = true
		guard writer.canAdd(input) else {
			throw NSError(
				domain: "SystemAudioCapture",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Unable to prepare the system audio writer."]
			)
		}
		writer.add(input)
	}

	func stream(
		_: SCStream,
		didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
		of outputType: SCStreamOutputType
	) {
		guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

		lock.lock()
		defer { lock.unlock() }
		guard writer.status != .failed, writer.status != .cancelled else { return }

		if !started {
			guard writer.startWriting() else {
				systemAudioCaptureLogger.error("Unable to start system audio writer: \(self.writer.error?.localizedDescription ?? "unknown error", privacy: .private)")
				return
			}
			let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
			writer.startSession(atSourceTime: start)
			started = true
			startedAt = start
		}

		if input.isReadyForMoreMediaData {
			if input.append(sampleBuffer) {
				let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
				let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
				latestSampleTime = sampleDuration.isValid
					? CMTimeAdd(presentationTime, sampleDuration)
					: presentationTime
			}
		}
	}

	func finish() async throws -> TimeInterval? {
		lock.lock()
		let didStart = started
		let startTime = startedAt
		let endTime = latestSampleTime
		if didStart { input.markAsFinished() }
		lock.unlock()

		guard didStart, let startTime else {
			writer.cancelWriting()
			return nil
		}

		try await withCheckedThrowingContinuation { continuation in
			writer.finishWriting {
				if self.writer.status == .completed {
					continuation.resume(returning: ())
				} else {
					continuation.resume(throwing: self.writer.error ?? NSError(
						domain: "SystemAudioCapture",
						code: 2,
						userInfo: [NSLocalizedDescriptionKey: "System audio export did not finish."]
					))
				}
			}
		}

		guard let endTime else { return 0 }
		return max(0, CMTimeGetSeconds(CMTimeSubtract(endTime, startTime)))
	}
}

private actor SystemAudioCaptureClientLive {
	private struct ActiveCapture {
		let stream: SCStream
		let writer: SystemAudioCaptureWriter
		let outputURL: URL
	}

	private var activeCapture: ActiveCapture?

	func startCapture() async -> SystemAudioCaptureStartResult {
		guard activeCapture == nil else { return .started }
		guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
			systemAudioCaptureLogger.notice("System audio capture needs Screen Recording permission")
			return .permissionDenied
		}

		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("octo-system-audio-\(UUID().uuidString)")
			.appendingPathExtension("m4a")

		do {
			let content = try await SCShareableContent.excludingDesktopWindows(
				false,
				onScreenWindowsOnly: true
			)
			guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
				?? content.displays.first
			else {
				throw NSError(
					domain: "SystemAudioCapture",
					code: 3,
					userInfo: [NSLocalizedDescriptionKey: "No display is available for system audio capture."]
				)
			}

			let filter = SCContentFilter(
				display: display,
				excludingApplications: [],
				exceptingWindows: []
			)
			let configuration = SCStreamConfiguration()
			configuration.capturesAudio = true
			configuration.excludesCurrentProcessAudio = true
			configuration.sampleRate = 48_000
			configuration.channelCount = 2
			configuration.width = 2
			configuration.height = 2

			let writer = try SystemAudioCaptureWriter(outputURL: outputURL)
			let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
			try stream.addStreamOutput(
				writer,
				type: .audio,
				sampleHandlerQueue: DispatchQueue(label: "io.github.blackforestboi.Octo.system-audio")
			)
			try await stream.startCapture()
			activeCapture = .init(stream: stream, writer: writer, outputURL: outputURL)
			systemAudioCaptureLogger.notice("Started system audio capture")
			return .started
		} catch {
			FileManager.default.removeItemIfExists(at: outputURL)
			systemAudioCaptureLogger.error("Failed to start system audio capture: \(error.localizedDescription, privacy: .private)")
			return .failed
		}
	}

	func stopCapture() async -> SystemAudioCaptureStopResult {
		guard let capture = activeCapture else { return .ignored(.noActiveCapture) }
		activeCapture = nil

		do {
			try await capture.stream.stopCapture()
			guard let duration = try await capture.writer.finish() else {
				FileManager.default.removeItemIfExists(at: capture.outputURL)
				return .ignored(.noCapturedAudio)
			}
			systemAudioCaptureLogger.notice("Stopped system audio capture after \(String(format: "%.2f", duration))s")
			return .captured(capture.outputURL, duration)
		} catch {
			FileManager.default.removeItemIfExists(at: capture.outputURL)
			systemAudioCaptureLogger.error("Failed to finalize system audio capture: \(error.localizedDescription, privacy: .private)")
			return .failed(error.localizedDescription)
		}
	}
}
