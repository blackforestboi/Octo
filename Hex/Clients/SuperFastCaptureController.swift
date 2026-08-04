import AVFoundation
import Darwin
import Foundation
import HexCore

private final class FloatRingBuffer {
  private let lock = NSLock()
  private var buffer: [Float]
  private var writeIndex = 0
  private var validSampleCount = 0

  init(capacity: Int) {
    buffer = Array(repeating: 0, count: max(1, capacity))
  }

  func append(_ samples: UnsafeBufferPointer<Float>) {
    guard !samples.isEmpty else { return }

    lock.lock()
    defer { lock.unlock() }

    for sample in samples {
      buffer[writeIndex] = sample
      writeIndex = (writeIndex + 1) % buffer.count
    }

    validSampleCount = min(buffer.count, validSampleCount + samples.count)
  }

  func recentSamples(count requestedCount: Int) -> [Float] {
    lock.lock()
    defer { lock.unlock() }

    let sampleCount = min(max(0, requestedCount), validSampleCount)
    guard sampleCount > 0 else { return [] }

    let startIndex = (writeIndex - sampleCount + buffer.count) % buffer.count
    if startIndex + sampleCount <= buffer.count {
      return Array(buffer[startIndex ..< startIndex + sampleCount])
    }

    let firstChunk = Array(buffer[startIndex ..< buffer.count])
    let secondChunk = Array(buffer[0 ..< (sampleCount - firstChunk.count)])
    return firstChunk + secondChunk
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }

    writeIndex = 0
    validSampleCount = 0
  }
}

private struct SuperFastCaptureConstants {
  static let sampleRate: Double = 16_000
  static let ringBufferDuration: TimeInterval = 1.0
  static let defaultPreRollDuration: TimeInterval = 0.45
  static let tapBufferSize: AVAudioFrameCount = 2_048
  static let stopDrainTimeout: TimeInterval = 2
}

enum CaptureRecordingMode: String {
  case standard = "standard"
  case superFast = "super-fast"

  var preRollDuration: TimeInterval {
    switch self {
    case .standard:
      0
    case .superFast:
      SuperFastCaptureConstants.defaultPreRollDuration
    }
  }

  var keepsWarmBuffer: Bool {
    self == .superFast
  }
}

final class SuperFastCaptureController {
  enum FinishRecordingResult {
    case captured(URL)
    case failed(RecordingFailure)
    case finalizing
    case idle
  }

  private struct PendingFinish {
    let targetHostTime: UInt64
    let postRollDuration: TimeInterval
    let clearBuffer: Bool
    let continuation: CheckedContinuation<FinishRecordingResult, Never>
  }

  private struct StopBoundary {
    let targetHostTime: UInt64
    var hasReachedTarget = false
  }

  private struct ActiveRecording {
    let recoverySession: RecordingRecoverySession
    let requestedAt: Date
    let prependedDuration: TimeInterval
    var didLogFirstBuffer: Bool
	var nextChunkSequence: Int
	var nextSample: Int64
  }

  private let logger = HexLog.recording
	private let processingQueue = DispatchQueue(label: "io.github.blackforestboi.Octo.SuperFastCapture")
	private let stopBoundaryLock = NSLock()
	private let inputTimelineLock = NSLock()
	private let meterContinuation: AsyncStream<Meter>.Continuation
	private let audioChunkRelay: CapturedAudioChunkRelay
  private let ringBuffer = FloatRingBuffer(
    capacity: Int(SuperFastCaptureConstants.sampleRate * SuperFastCaptureConstants.ringBufferDuration)
  )
  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: SuperFastCaptureConstants.sampleRate,
    channels: 1,
    interleaved: false
  )!

  private var engine: AVAudioEngine?
  private var converter: AVAudioConverter?
  private var inputTimelineLatency: TimeInterval = 0
  private var configurationChangeObserver: NSObjectProtocol?
  private var activeRecording: ActiveRecording?
  /// A synchronously-written PCM source whose capture stream failed. It stays available until
  /// the stop path can convert the valid prefix to WAV and place it in History.
  private var failedRecoverySession: RecordingRecoverySession?
  private var captureGeneration = 0
  private var recordingFailure: RecordingFailure?
  private var keepWarmBuffer = false
  private var stopBoundary: StopBoundary?
  private var pendingFinish: PendingFinish?
  private var pendingFinishWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstAudioBufferWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  private var stopDrainTimeoutTask: Task<Void, Never>?
  private let onEngineConfigurationChange: @Sendable (Int) -> Void

  init(
    meterContinuation: AsyncStream<Meter>.Continuation,
	audioChunkRelay: CapturedAudioChunkRelay,
    onEngineConfigurationChange: @escaping @Sendable (Int) -> Void
  ) {
    self.meterContinuation = meterContinuation
	self.audioChunkRelay = audioChunkRelay
    self.onEngineConfigurationChange = onEngineConfigurationChange
  }

  deinit {
    stop()
  }

  var isRunning: Bool {
    engine?.isRunning == true
  }

  var isRecording: Bool {
    processingQueue.sync { activeRecording != nil }
  }

  func startIfNeeded(reason: String = "unknown", keepWarmBuffer: Bool = false) throws {
    processingQueue.sync {
      let didDisableWarmBuffer = self.keepWarmBuffer && !keepWarmBuffer
      self.keepWarmBuffer = keepWarmBuffer
      if didDisableWarmBuffer, activeRecording == nil {
        ringBuffer.clear()
      }
    }

    if engine?.isRunning == true {
      logger.debug("Capture engine already armed reason=\(reason)")
      return
    }

    stop(reason: "restart-before-arm")
    try armEngine(reason: reason)
  }

  /// Tears down and recreates the engine while keeping the active recording file open, so
  /// capture resumes onto the same file after a device/route change mid-recording
  /// (#251, #252, #218, #226). The ring buffer and active recording survive;
  /// only the engine, tap, and converter are rebuilt.
  func restartPreservingRecording(reason: String) throws {
    logger.notice("Restarting capture engine preserving active recording reason=\(reason)")
    detachEngine()
    try armEngine(reason: reason)
  }

  private func armEngine(reason: String) throws {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw NSError(
        domain: "SuperFastCapture",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to create the capture engine audio converter."]
      )
    }
    if inputFormat.channelCount > 1 {
      converter.channelMap = [NSNumber(value: 0)]
    }

    let generation = processingQueue.sync {
      captureGeneration += 1
      self.converter = converter
      recordingFailure = nil
      return captureGeneration
    }

    inputNode.installTap(onBus: 0, bufferSize: SuperFastCaptureConstants.tapBufferSize, format: inputFormat) {
      [weak self] buffer, time in
      self?.enqueue(buffer, time: time, generation: generation)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      processingQueue.sync {
        captureGeneration += 1
        self.converter = nil
      }
      throw error
    }
    let inputTimelineLatency = max(0, inputNode.presentationLatency) + max(0, inputNode.latency)
    setInputTimelineLatency(inputTimelineLatency)
    self.engine = engine
    configurationChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: .main
    ) { [weak self] _ in
      self?.handleConfigurationChange(generation: generation)
    }
    logger.notice(
      "Capture engine armed reason=\(reason) sampleRate=\(String(format: "%.0f", inputFormat.sampleRate))Hz channels=\(inputFormat.channelCount) inputTimelineLatency=\(String(format: "%.3f", inputTimelineLatency))s ringBuffer=\(String(format: "%.2f", SuperFastCaptureConstants.ringBufferDuration))s defaultPreRoll=\(String(format: "%.2f", SuperFastCaptureConstants.defaultPreRollDuration))s"
    )
  }

  func stop(reason: String = "unknown") {
    if engine != nil {
      logger.notice("Capture engine stopped reason=\(reason)")
    }
    detachEngine(clearingRecordingState: true)
  }

  /// Removes the tap, observer, converter, and engine. Bumps the capture generation so
  /// in-flight tap callbacks from the old engine are ignored. Recording state (active file,
  /// ring buffer, timing metrics) is preserved unless `clearingRecordingState` is set, which
  /// is what lets restartPreservingRecording resume capture onto the same file.
  private func detachEngine(clearingRecordingState: Bool = false) {
    if let inputNode = engine?.inputNode {
      inputNode.removeTap(onBus: 0)
    }
    if let configurationChangeObserver {
      NotificationCenter.default.removeObserver(configurationChangeObserver)
      self.configurationChangeObserver = nil
    }
    processingQueue.sync {
      captureGeneration += 1
      converter = nil
      if clearingRecordingState {
        activeRecording?.recoverySession.abandonForRecovery()
        resolvePendingFinish(with: .idle)
        clearStopBoundary()
        activeRecording = nil
        recordingFailure = nil
        ringBuffer.clear()
        resumeFirstAudioBufferWaiters(receivedAudio: false)
      }
    }
    engine?.stop()
    engine = nil
    setInputTimelineLatency(0)
  }

  private func handleConfigurationChange(generation: Int) {
    guard processingQueue.sync(execute: { Self.shouldProcessCallback(callbackGeneration: generation, currentGeneration: captureGeneration) }) else {
      return
    }
    logger.notice("Capture engine configuration changed")
    onEngineConfigurationChange(generation)
  }

  static func shouldProcessCallback(callbackGeneration: Int, currentGeneration: Int) -> Bool {
    callbackGeneration == currentGeneration
  }

  func isCurrentGeneration(_ generation: Int) -> Bool {
    processingQueue.sync { generation == captureGeneration }
  }

  func beginRecording(
    recoverySession: RecordingRecoverySession,
    requestedAt: Date = Date(),
    mode: CaptureRecordingMode
  ) throws {
    try startIfNeeded(reason: "begin-recording", keepWarmBuffer: mode.keepsWarmBuffer)

    var startError: Error?
    processingQueue.sync {
      do {
        recordingFailure = nil
        failedRecoverySession = nil
        let preRollDuration = mode.preRollDuration
        let preRollFrameCount = Int(preRollDuration * SuperFastCaptureConstants.sampleRate)
        let preRollSamples = ringBuffer.recentSamples(count: preRollFrameCount)
        let prependedDuration = Double(preRollSamples.count) / SuperFastCaptureConstants.sampleRate
        if !preRollSamples.isEmpty {
          try preRollSamples.withUnsafeBufferPointer { samples in
            try recoverySession.append(samples)
          }
        }

        logger.notice(
          "Capture engine durable PCM source opened prepended=\(String(format: "%.3f", prependedDuration))s requestedPreRoll=\(String(format: "%.3f", preRollDuration))s"
        )
        activeRecording = ActiveRecording(
          recoverySession: recoverySession,
          requestedAt: requestedAt,
          prependedDuration: prependedDuration,
          didLogFirstBuffer: false,
		  nextChunkSequence: preRollSamples.isEmpty ? 0 : 1,
		  nextSample: Int64(preRollSamples.count)
        )
		if !preRollSamples.isEmpty {
			let chunk = CapturedAudioChunk(
				source: .microphone,
				takeGeneration: recoverySession.id,
				sequence: 0,
				startSample: 0,
				samples: preRollSamples
			)
			if audioChunkRelay.yield(chunk) {
				audioChunkRelay.yield(.init(
					source: .microphone,
					takeGeneration: recoverySession.id,
					sequence: 1,
					startSample: Int64(preRollSamples.count),
					samples: [],
					discontinuityBefore: true
				))
				activeRecording?.nextChunkSequence = 2
			}
		}
      } catch {
        startError = error
      }
    }

    if let startError {
      throw startError
    }
  }

  /// Wait for the first frame received after a recording begins. Starting a durable PCM file
  /// only proves that we could open storage; this confirms that Core Audio is actually feeding
  /// the selected microphone into the capture path.
  func waitForFirstAudioBuffer(timeout: Duration) async -> Bool {
    let waiterID = UUID()
    return await withCheckedContinuation { continuation in
      processingQueue.async { [weak self] in
        guard let self, let recording = self.activeRecording else {
          continuation.resume(returning: false)
          return
        }
        guard !recording.didLogFirstBuffer else {
          continuation.resume(returning: true)
          return
        }

        self.firstAudioBufferWaiters[waiterID] = continuation
        Task { [weak self] in
          try? await Task.sleep(for: timeout)
          guard !Task.isCancelled else { return }
          self?.resumeFirstAudioBufferWaiter(id: waiterID, receivedAudio: false)
        }
      }
    }
  }

  /// Atomically discard a session that is still waiting for its first input frame. If a frame
  /// arrived as the timeout fired, the caller keeps the recording instead.
  func cancelRecordingIfNoAudioReceived() -> Bool {
    processingQueue.sync {
      discardRecordingIfNoAudioReceived()
    }
  }

  /// Prevents a new capture file from replacing one that is still draining its final PCM
  /// frames. RecordingClient awaits this before it opens a new session.
  func waitForPendingFinish() async {
    await withCheckedContinuation { continuation in
      processingQueue.async { [weak self] in
        guard let self, self.pendingFinish != nil || self.currentStopBoundary() != nil else {
          continuation.resume()
          return
        }
        self.pendingFinishWaiters.append(continuation)
      }
    }
  }

  /// Establishes the audio cutoff from the physical input event before reducer and actor
  /// scheduling can move the boundary. A tap's timestamp describes capture at the input node's
  /// output, after hardware/stream and node processing latency, so translate the physical event
  /// into that timeline. This is timestamp compensation, not post-roll audio.
  func requestStopBoundary(
    eventTimestampNanoseconds: UInt64?,
    postRollDuration: TimeInterval = 0
  ) {
    let eventHostTime = eventTimestampNanoseconds.map { Self.hostTimeForEventTimestamp($0) }
      ?? mach_absolute_time()
    let targetHostTime = Self.stopBoundaryHostTime(
      eventHostTime: eventHostTime,
      inputTimelineLatency: currentInputTimelineLatency(),
      postRollDuration: postRollDuration
    )
    _ = installStopBoundary(targetHostTime)
  }

  /// Finalizes at an audio-clock boundary rather than after a wall-clock delay. The hotkey
  /// event supplies the boundary in host time; tap timestamps let us retain every PCM frame
  /// through that point even when Core Audio delivers the final buffer late.
  func finishRecording(
    clearBuffer: Bool = true,
    postRollDuration: TimeInterval = 0
  ) async -> FinishRecordingResult {
    let postRollDuration = max(0, postRollDuration)
    let targetHostTime: UInt64
    if let requestedBoundary = currentStopBoundary() {
      targetHostTime = requestedBoundary.targetHostTime
    } else {
      targetHostTime = Self.stopBoundaryHostTime(
        eventHostTime: mach_absolute_time(),
        inputTimelineLatency: currentInputTimelineLatency(),
        postRollDuration: postRollDuration
      )
      guard installStopBoundary(targetHostTime) else {
        return .finalizing
      }
    }

    return await withCheckedContinuation { continuation in
      processingQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: .idle)
          return
        }
        guard self.pendingFinish == nil else {
          continuation.resume(returning: .finalizing)
          return
        }
        guard self.activeRecording != nil else {
          self.clearStopBoundary()
          continuation.resume(returning: self.finishResult())
          self.resumePendingFinishWaiters()
          return
        }

        if self.discardRecordingIfNoAudioReceived() {
          continuation.resume(returning: .failed(.microphoneUnavailable))
          self.resumePendingFinishWaiters()
          return
        }

        self.pendingFinish = PendingFinish(
          targetHostTime: targetHostTime,
          postRollDuration: postRollDuration,
          clearBuffer: clearBuffer,
          continuation: continuation
        )
        if self.hasReachedStopBoundary(targetHostTime) {
          self.resolvePendingFinish(with: self.finishResult())
          return
        }
        self.scheduleStopDrainTimeout()
      }
    }
  }

  static func hostTimeForEventTimestamp(_ timestampNanoseconds: UInt64) -> UInt64 {
    AVAudioTime.hostTime(forSeconds: Double(timestampNanoseconds) / 1_000_000_000)
  }

  static func stopBoundaryHostTime(
    eventHostTime: UInt64,
    inputTimelineLatency: TimeInterval,
    postRollDuration: TimeInterval
  ) -> UInt64 {
    let timelineOffset = max(0, inputTimelineLatency) + max(0, postRollDuration)
    let offsetHostTime = AVAudioTime.hostTime(forSeconds: timelineOffset)
    let (targetHostTime, overflow) = eventHostTime.addingReportingOverflow(offsetHostTime)
    return overflow ? .max : targetHostTime
  }

  private func enqueue(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, generation: Int) {
    guard let copy = clone(buffer) else { return }
    processingQueue.async { [weak self] in
      self?.process(copy, time: time, generation: generation)
    }
  }

  private func process(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, generation: Int) {
    guard Self.shouldProcessCallback(callbackGeneration: generation, currentGeneration: captureGeneration) else {
      return
    }

    guard let converted = convert(buffer),
          converted.frameLength > 0,
          let samples = converted.floatChannelData?[0]
    else {
      return
    }

    let sampleCount = Int(converted.frameLength)
    if keepWarmBuffer, activeRecording == nil {
      ringBuffer.append(UnsafeBufferPointer(start: samples, count: sampleCount))
    }

    if activeRecording != nil {
      meterContinuation.yield(meter(for: samples, count: sampleCount))
    }

    guard var recording = activeRecording else { return }
    if !recording.didLogFirstBuffer {
      let timeToFirstBuffer = Date().timeIntervalSince(recording.requestedAt)
      logger.notice(
        "Capture engine first buffer latency=\(String(format: "%.3f", timeToFirstBuffer))s prepended=\(String(format: "%.3f", recording.prependedDuration))s frames=\(sampleCount)"
      )
      recording.didLogFirstBuffer = true
      activeRecording = recording
      resumeFirstAudioBufferWaiters(receivedAudio: true)
    }

    let stopBoundary = currentStopBoundary()
    let inputFramesToWrite: Int
    if let stopBoundary,
       time.isHostTimeValid
    {
      inputFramesToWrite = Self.inputFramesToWrite(
        bufferStartHostTime: time.hostTime,
        inputSampleRate: buffer.format.sampleRate,
        inputFrameCount: Int(buffer.frameLength),
        targetHostTime: stopBoundary.targetHostTime
      )
    } else {
      inputFramesToWrite = Int(buffer.frameLength)
    }

    let outputFramesToWrite = Self.outputFramesToWrite(
      convertedFrameCount: Int(converted.frameLength),
      inputFrameCount: Int(buffer.frameLength),
      inputFramesToWrite: inputFramesToWrite
    )

    do {
      if outputFramesToWrite > 0 {
        converted.frameLength = AVAudioFrameCount(outputFramesToWrite)
        try recording.recoverySession.append(
          UnsafeBufferPointer(start: samples, count: outputFramesToWrite)
        )
		let chunkSamples = Array(UnsafeBufferPointer(start: samples, count: outputFramesToWrite))
		let chunk = CapturedAudioChunk(
			source: .microphone,
			takeGeneration: recording.recoverySession.id,
			sequence: recording.nextChunkSequence,
			startSample: recording.nextSample,
			samples: chunkSamples
		)
		if audioChunkRelay.yield(chunk) {
			audioChunkRelay.yield(.init(
				source: .microphone,
				takeGeneration: recording.recoverySession.id,
				sequence: recording.nextChunkSequence + 1,
				startSample: recording.nextSample + Int64(outputFramesToWrite),
				samples: [],
				discontinuityBefore: true
			))
			recording.nextChunkSequence += 1
		}
		recording.nextChunkSequence += 1
		recording.nextSample += Int64(outputFramesToWrite)
		activeRecording = recording
      }
      if let stopBoundary,
         time.isHostTimeValid,
         Self.bufferStartsAtOrAfterTarget(
           bufferStartHostTime: time.hostTime,
           targetHostTime: stopBoundary.targetHostTime
         )
      {
        markStopBoundaryReached(stopBoundary.targetHostTime)
        if let pendingFinish {
          let postRollDescription = String(format: "%.3f", pendingFinish.postRollDuration)
          logger.notice("Capture engine finalizing at audio boundary postRoll=\(postRollDescription)s")
          resolvePendingFinish(with: finalize(recording))
        }
      }
    } catch {
      logger.error("Failed to write capture engine audio: \(error.localizedDescription)")
      activeRecording = nil
      recordingFailure = .captureWriteFailed(error.localizedDescription)
      failedRecoverySession = recording.recoverySession
      recording.recoverySession.abandonForRecovery()
      resolvePendingFinish(with: .failed(.captureWriteFailed(error.localizedDescription)))
    }
  }

  /// Maps the desired host-clock boundary onto the buffer's PCM timeline. This uses Core
  /// Audio's timestamp rather than queue or wall-clock timing, so delayed callbacks do not
  /// discard samples that were captured before the stop boundary.
  static func inputFramesToWrite(
    bufferStartHostTime: UInt64,
    inputSampleRate: Double,
    inputFrameCount: Int,
    targetHostTime: UInt64
  ) -> Int {
    guard inputSampleRate > 0, inputFrameCount > 0, targetHostTime > bufferStartHostTime else {
      return 0
    }
    let secondsToTarget = AVAudioTime.seconds(forHostTime: targetHostTime - bufferStartHostTime)
    let frameCount = Int((secondsToTarget * inputSampleRate).rounded(.down))
    return min(max(frameCount, 0), inputFrameCount)
  }

  static func outputFramesToWrite(
    convertedFrameCount: Int,
    inputFrameCount: Int,
    inputFramesToWrite: Int
  ) -> Int {
    guard convertedFrameCount > 0, inputFrameCount > 0, inputFramesToWrite > 0 else {
      return 0
    }
    let ratio = Double(inputFramesToWrite) / Double(inputFrameCount)
    return min(
      convertedFrameCount,
      max(1, Int((Double(convertedFrameCount) * ratio).rounded(.down)))
    )
  }

  /// Finalization waits until Core Audio delivers a buffer beginning at or after the cutoff.
  /// The buffer containing the cutoff is processed first; this subsequent timestamp is the
  /// condition-based proof that the callback stream has drained through the requested frame.
  static func bufferStartsAtOrAfterTarget(
    bufferStartHostTime: UInt64,
    targetHostTime: UInt64
  ) -> Bool {
    bufferStartHostTime >= targetHostTime
  }

  private func installStopBoundary(_ targetHostTime: UInt64) -> Bool {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    guard stopBoundary == nil else { return false }
    stopBoundary = StopBoundary(targetHostTime: targetHostTime)
    return true
  }

  private func currentStopBoundary() -> StopBoundary? {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    return stopBoundary
  }

  private func markStopBoundaryReached(_ targetHostTime: UInt64) {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    guard stopBoundary?.targetHostTime == targetHostTime else { return }
    stopBoundary?.hasReachedTarget = true
  }

  private func hasReachedStopBoundary(_ targetHostTime: UInt64) -> Bool {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    return stopBoundary?.targetHostTime == targetHostTime && stopBoundary?.hasReachedTarget == true
  }

  private func clearStopBoundary() {
    stopBoundaryLock.lock()
    defer { stopBoundaryLock.unlock() }
    stopBoundary = nil
  }

  private func setInputTimelineLatency(_ latency: TimeInterval) {
    inputTimelineLock.lock()
    defer { inputTimelineLock.unlock() }
    inputTimelineLatency = max(0, latency)
  }

  private func currentInputTimelineLatency() -> TimeInterval {
    inputTimelineLock.lock()
    defer { inputTimelineLock.unlock() }
    return inputTimelineLatency
  }

  private func scheduleStopDrainTimeout() {
    stopDrainTimeoutTask?.cancel()
    stopDrainTimeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(SuperFastCaptureConstants.stopDrainTimeout))
      guard !Task.isCancelled else { return }
      self?.processingQueue.async { [weak self] in
        guard let self, self.pendingFinish != nil else { return }
        self.logger.error("Timed out waiting for capture engine to reach the stop audio boundary")
        let failure = RecordingFailure.captureFinalizationTimedOut
        if let recording = self.activeRecording {
          self.failedRecoverySession = recording.recoverySession
          recording.recoverySession.abandonForRecovery()
        }
        self.resolvePendingFinish(with: .failed(failure))
      }
    }
  }

  private func finishResult() -> FinishRecordingResult {
    if let recordingFailure {
      return .failed(recordingFailure)
    }
    if let recording = activeRecording {
      return finalize(recording)
    }
    return .idle
  }

  private func finalize(_ recording: ActiveRecording) -> FinishRecordingResult {
    do {
      return .captured(try recording.recoverySession.finalize().audioURL)
    } catch {
      logger.error("Failed to finalize durable capture source: \(error.localizedDescription, privacy: .private)")
      failedRecoverySession = recording.recoverySession
      recording.recoverySession.abandonForRecovery()
      return .failed(.captureWriteFailed(error.localizedDescription))
    }
  }

  /// Finalize a capture that stopped because the streaming write failed. The raw PCM prefix is
  /// fsynced before the failure is surfaced, so this turns every accepted frame into replayable
  /// WAV without waiting for the next app launch.
  func recoverFailedRecording() -> RecoveredRecording? {
    let session = processingQueue.sync { failedRecoverySession }
    guard let session else { return nil }

    do {
      let recovered = try session.finalize()
      processingQueue.sync {
        if failedRecoverySession === session {
          failedRecoverySession = nil
        }
      }
      logger.notice("Finalized recoverable PCM after capture failure duration=\(String(format: "%.3f", recovered.duration))s")
      return recovered
    } catch {
      logger.error("Could not finalize recoverable PCM after capture failure: \(error.localizedDescription, privacy: .private)")
      return nil
    }
  }

  private func resolvePendingFinish(with result: FinishRecordingResult) {
    guard let pendingFinish else { return }
    self.pendingFinish = nil
    clearStopBoundary()
    stopDrainTimeoutTask?.cancel()
    stopDrainTimeoutTask = nil
    activeRecording = nil
    recordingFailure = nil
    if pendingFinish.clearBuffer {
      ringBuffer.clear()
    }
    pendingFinish.continuation.resume(returning: result)
    resumePendingFinishWaiters()
  }

  private func resumePendingFinishWaiters() {
    let waiters = pendingFinishWaiters
    pendingFinishWaiters.removeAll(keepingCapacity: false)
    waiters.forEach { $0.resume() }
  }

  private func discardRecordingIfNoAudioReceived() -> Bool {
    guard let recording = activeRecording, !recording.didLogFirstBuffer else { return false }

    logger.error("Capture engine stopped before receiving a microphone audio buffer")
    recording.recoverySession.abandonForRecovery()
    RecordingRecoveryStore.releaseSource(for: recording.recoverySession.id)
    activeRecording = nil
    recordingFailure = nil
    clearStopBoundary()
    ringBuffer.clear()
    resumeFirstAudioBufferWaiters(receivedAudio: false)
    return true
  }

  private func resumeFirstAudioBufferWaiter(id: UUID, receivedAudio: Bool) {
    processingQueue.async { [weak self] in
      self?.firstAudioBufferWaiters.removeValue(forKey: id)?.resume(returning: receivedAudio)
    }
  }

  private func resumeFirstAudioBufferWaiters(receivedAudio: Bool) {
    let waiters = firstAudioBufferWaiters.values
    firstAudioBufferWaiters.removeAll(keepingCapacity: false)
    waiters.forEach { $0.resume(returning: receivedAudio) }
  }

  private func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let converter else { return nil }

    let sampleRateRatio = targetFormat.sampleRate / inputBuffer.format.sampleRate
    let frameCapacity = AVAudioFrameCount(
      max(1, (Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32)
    )

    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
      return nil
    }

    var error: NSError?
    var consumedInput = false
    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if consumedInput {
        outStatus.pointee = .noDataNow
        return nil
      }

      consumedInput = true
      outStatus.pointee = .haveData
      return inputBuffer
    }

    if let error {
      logger.error("Failed to convert capture engine audio: \(error.localizedDescription)")
      return nil
    }

    switch status {
    case .haveData, .inputRanDry, .endOfStream:
      return outputBuffer.frameLength > 0 ? outputBuffer : nil
    case .error:
      return nil
    @unknown default:
      return nil
    }
  }

  private func meter(for samples: UnsafePointer<Float>, count: Int) -> Meter {
    guard count > 0 else {
      return Meter(averagePower: 0, peakPower: 0)
    }

    var sumOfSquares: Float = 0
    var peak: Float = 0
    for index in 0 ..< count {
      let sample = samples[index]
      let magnitude = abs(sample)
      sumOfSquares += sample * sample
      peak = max(peak, magnitude)
    }

    let rms = sqrt(sumOfSquares / Float(count))
    return Meter(averagePower: Double(rms), peakPower: Double(peak))
  }

  private func clone(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
      return nil
    }

    copy.frameLength = buffer.frameLength

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for index in sourceBuffers.indices {
      let source = sourceBuffers[index]
      let destination = destinationBuffers[index]
      guard let sourceData = source.mData, let destinationData = destination.mData else { continue }
      memcpy(destinationData, sourceData, Int(source.mDataByteSize))
      destinationBuffers[index].mDataByteSize = source.mDataByteSize
    }

    return copy
  }

}
