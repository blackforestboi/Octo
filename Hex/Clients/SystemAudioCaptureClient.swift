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
	case started(Date)
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
	var startCapture: @Sendable (_ parentRecordingSessionID: UUID) async -> SystemAudioCaptureStartResult = { _ in .failed }
	var stopCapture: @Sendable () async -> SystemAudioCaptureStopResult = { .ignored(.noActiveCapture) }
	var observeAudioLevel: @Sendable () async -> AsyncStream<Meter> = { AsyncStream { _ in } }
	var recoverInterruptedRecordings: @Sendable () async -> [RecoveredSystemAudioRecording] = { [] }
	var cleanup: @Sendable () async -> Void = {}
}

extension SystemAudioCaptureClient: DependencyKey {
	static let liveValue: Self = {
		let live = SystemAudioCaptureClientLive()
		return Self(
			startCapture: { await live.startCapture(parentRecordingSessionID: $0) },
			stopCapture: { await live.stopCapture() },
			observeAudioLevel: { await live.observeAudioLevel() },
			recoverInterruptedRecordings: { await live.recoverInterruptedRecordings() },
			cleanup: { await live.cleanup() }
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
	private let session: SystemAudioRecoverySession
	private let meterContinuation: AsyncStream<Meter>.Continuation
	private var appendError: Swift.Error?

	init(session: SystemAudioRecoverySession, meterContinuation: AsyncStream<Meter>.Continuation) {
		self.session = session
		self.meterContinuation = meterContinuation
	}

	func stream(
		_: SCStream,
		didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
		of outputType: SCStreamOutputType
	) {
		guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

		lock.lock()
		defer { lock.unlock() }
		guard appendError == nil else { return }
		do {
			let (pcm, frameCount) = try Self.interleavedFloat32PCM(from: sampleBuffer)
			meterContinuation.yield(Self.meter(for: pcm))
			try session.appendInterleavedPCM(pcm, frameCount: frameCount)
		} catch {
			appendError = error
			systemAudioCaptureLogger.error("Failed to append system audio PCM: \(error.localizedDescription, privacy: .private)")
		}
	}

	private static func meter(for pcm: Data) -> Meter {
		pcm.withUnsafeBytes { rawBuffer in
			let samples = rawBuffer.bindMemory(to: Float.self)
			guard !samples.isEmpty else { return Meter(averagePower: 0, peakPower: 0) }
			var sumOfSquares: Float = 0
			var peak: Float = 0
			for sample in samples {
				sumOfSquares += sample * sample
				peak = max(peak, abs(sample))
			}
			return Meter(
				averagePower: Double(sqrt(sumOfSquares / Float(samples.count))),
				peakPower: Double(peak)
			)
		}
	}

	func finish() throws -> RecoveredSystemAudioRecording? {
		lock.lock()
		defer { lock.unlock() }
		let recovered = try session.finalize()
		if recovered != nil, let appendError {
			// A valid synchronized prefix is still valuable. Return it to History and surface
			// the truncation in diagnostics instead of deleting the entire recording.
			systemAudioCaptureLogger.warning("System audio was finalized after a PCM append error: \(appendError.localizedDescription, privacy: .private)")
		}
		return recovered
	}

	func abandonForRecovery() {
		lock.lock()
		defer { lock.unlock() }
		session.abandonForRecovery()
	}

	private static func interleavedFloat32PCM(from sampleBuffer: CMSampleBuffer) throws -> (Data, Int) {
		guard let description = sampleBuffer.formatDescription,
			let streamDescription = description.audioStreamBasicDescription,
			streamDescription.mFormatID == kAudioFormatLinearPCM,
			streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
			streamDescription.mBitsPerChannel == 32,
			streamDescription.mChannelsPerFrame == SystemAudioRecoveryStore.channelCount,
			abs(streamDescription.mSampleRate - SystemAudioRecoveryStore.sampleRate) < 0.5
		else {
			throw SystemAudioRecoveryStore.Error.invalidPCMBuffer
		}

		let frameCount = sampleBuffer.numSamples
		guard frameCount > 0 else { return (Data(), 0) }
		return try sampleBuffer.withAudioBufferList { bufferList, _ in
			if bufferList.count == 1 {
				let buffer = bufferList[0]
				let byteCount = frameCount * SystemAudioRecoveryStore.bytesPerFrame
				guard buffer.mNumberChannels == SystemAudioRecoveryStore.channelCount,
					Int(buffer.mDataByteSize) >= byteCount,
					let source = buffer.mData
				else { throw SystemAudioRecoveryStore.Error.invalidPCMBuffer }
				return (Data(bytes: source, count: byteCount), frameCount)
			}

			guard bufferList.count == SystemAudioRecoveryStore.channelCount else {
				throw SystemAudioRecoveryStore.Error.invalidPCMBuffer
			}
			let bytesPerChannel = frameCount * SystemAudioRecoveryStore.bytesPerSample
			let channels: [UnsafePointer<Float>] = try (0..<SystemAudioRecoveryStore.channelCount).map { index in
				let buffer = bufferList[index]
				guard buffer.mNumberChannels == 1,
					Int(buffer.mDataByteSize) >= bytesPerChannel,
					let source = buffer.mData
				else { throw SystemAudioRecoveryStore.Error.invalidPCMBuffer }
				return UnsafeRawPointer(source).assumingMemoryBound(to: Float.self)
			}
			var interleaved = Data(count: frameCount * SystemAudioRecoveryStore.bytesPerFrame)
			interleaved.withUnsafeMutableBytes { rawDestination in
				let destination = rawDestination.bindMemory(to: Float.self)
				for frame in 0..<frameCount {
					for channel in 0..<SystemAudioRecoveryStore.channelCount {
						destination[frame * SystemAudioRecoveryStore.channelCount + channel] = channels[channel][frame]
					}
				}
			}
			return (interleaved, frameCount)
		}
	}
}

private actor SystemAudioCaptureClientLive {
	private struct ActiveCapture {
		let id: UUID
		let parentRecordingSessionID: UUID
		let stream: SCStream
		let writer: SystemAudioCaptureWriter
		let startedAt: Date
	}

	private enum CapturePhase {
		case starting(ActiveCapture)
		case started(ActiveCapture)
		case stopping(UUID)
	}

	private let recoveryStore = SystemAudioRecoveryStore()
	private let (meterStream, meterContinuation) = AsyncStream<Meter>.makeStream()
	private var pendingStartID: UUID?
	private var capturePhase: CapturePhase?

	func startCapture(parentRecordingSessionID: UUID) async -> SystemAudioCaptureStartResult {
		if case let .started(capture) = capturePhase,
			capture.parentRecordingSessionID == parentRecordingSessionID
		{
			return .started(capture.startedAt)
		}
		guard pendingStartID == nil, capturePhase == nil else {
			systemAudioCaptureLogger.error("Refusing to overlap system audio capture sessions")
			return .failed
		}

		let startID = UUID()
		pendingStartID = startID
		guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
			pendingStartID = nil
			systemAudioCaptureLogger.notice("System audio capture needs Screen Recording permission")
			return .permissionDenied
		}

		var recoverySession: SystemAudioRecoverySession?
		var pendingCapture: ActiveCapture?
		do {
			let content = try await SCShareableContent.excludingDesktopWindows(
				false,
				onScreenWindowsOnly: true
			)
			guard pendingStartID == startID, !Task.isCancelled else {
				if pendingStartID == startID { pendingStartID = nil }
				return .failed
			}
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
			configuration.sampleRate = Int(SystemAudioRecoveryStore.sampleRate)
			configuration.channelCount = SystemAudioRecoveryStore.channelCount
			configuration.width = 2
			configuration.height = 2

			let startedAt = Date()
			let session = try recoveryStore.begin(
				parentRecordingSessionID: parentRecordingSessionID,
				createdAt: startedAt
			)
			recoverySession = session
			let writer = SystemAudioCaptureWriter(session: session, meterContinuation: meterContinuation)
			let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
			try stream.addStreamOutput(
				writer,
				type: .audio,
				sampleHandlerQueue: DispatchQueue(label: "io.github.blackforestboi.Octo.system-audio")
			)
			let captureID = UUID()
			let capture = ActiveCapture(
				id: captureID,
				parentRecordingSessionID: parentRecordingSessionID,
				stream: stream,
				writer: writer,
				startedAt: startedAt
			)
			pendingCapture = capture
			pendingStartID = nil
			capturePhase = .starting(capture)
			try await stream.startCapture()

			// stopCapture() can run while ScreenCaptureKit is suspended in startCapture().
			// In that case it owns finalization; never resurrect the stopped stream here.
			guard case let .starting(currentCapture) = capturePhase,
				currentCapture.id == captureID
			else { return .failed }
			guard !Task.isCancelled else {
				capturePhase = .stopping(captureID)
				try? await stream.stopCapture()
				finalizeAfterFailedStart(capture)
				clearStoppingPhase(captureID)
				return .failed
			}
			capturePhase = .started(capture)
			systemAudioCaptureLogger.notice("Started durable PCM system audio capture")
			return .started(startedAt)
		} catch {
			if pendingStartID == startID {
				pendingStartID = nil
			}
			if let pendingCapture,
				case let .starting(currentCapture) = capturePhase,
				currentCapture.id == pendingCapture.id
			{
				capturePhase = .stopping(pendingCapture.id)
				try? await pendingCapture.stream.stopCapture()
				finalizeAfterFailedStart(pendingCapture)
				clearStoppingPhase(pendingCapture.id)
			} else if case nil = pendingCapture {
				do {
					_ = try recoverySession?.finalize()
				} catch {
					recoverySession?.abandonForRecovery()
				}
			}
			systemAudioCaptureLogger.error("Failed to start system audio capture: \(error.localizedDescription, privacy: .private)")
			return .failed
		}
	}

	func stopCapture() async -> SystemAudioCaptureStopResult {
		if pendingStartID != nil {
			// Invalidates a start that is currently awaiting ScreenCaptureKit discovery.
			pendingStartID = nil
		}
		let capture: ActiveCapture
		switch capturePhase {
		case let .starting(currentCapture), let .started(currentCapture):
			capture = currentCapture
			capturePhase = .stopping(currentCapture.id)
		case .stopping, .none:
			return .ignored(.noActiveCapture)
		}

		var streamStopError: Swift.Error?
		do {
			try await capture.stream.stopCapture()
		} catch {
			streamStopError = error
			systemAudioCaptureLogger.warning("System audio stream stop failed; finalizing its durable prefix: \(error.localizedDescription, privacy: .private)")
		}

		do {
			guard let recovered = try capture.writer.finish() else {
				clearStoppingPhase(capture.id)
				if let streamStopError { return .failed(streamStopError.localizedDescription) }
				return .ignored(.noCapturedAudio)
			}
			clearStoppingPhase(capture.id)
			systemAudioCaptureLogger.notice("Stopped durable system audio capture after \(String(format: "%.2f", recovered.duration))s")
			return .captured(recovered.audioURL, recovered.duration)
		} catch {
			capture.writer.abandonForRecovery()
			clearStoppingPhase(capture.id)
			systemAudioCaptureLogger.error("Failed to finalize system audio capture; keeping it for next-launch recovery: \(error.localizedDescription, privacy: .private)")
			return .failed(error.localizedDescription)
		}
	}

	func recoverInterruptedRecordings() -> [RecoveredSystemAudioRecording] {
		recoveryStore.recoverInterruptedRecordings()
	}

	func observeAudioLevel() -> AsyncStream<Meter> {
		meterStream
	}

	func cleanup() async {
		_ = await stopCapture()
	}

	private func finalizeAfterFailedStart(_ capture: ActiveCapture) {
		do {
			_ = try capture.writer.finish()
		} catch {
			capture.writer.abandonForRecovery()
			systemAudioCaptureLogger.error("Could not finalize a failed system audio start; keeping it for recovery: \(error.localizedDescription, privacy: .private)")
		}
	}

	private func clearStoppingPhase(_ captureID: UUID) {
		guard case let .stopping(currentID) = capturePhase, currentID == captureID else { return }
		capturePhase = nil
	}
}
