import AVFoundation
import Foundation
import HexCore

/// The durable source of truth for an in-progress recording.
///
/// WAV files need their header updated when they are closed, so a WAV written directly by the
/// capture callback cannot be relied on after a hard termination. This store instead persists
/// the converted PCM frames as they are accepted. Both a regular stop and next-launch recovery
/// use `finalize()` to turn that one source into the WAV consumed by the rest of the app.
final class RecordingRecoverySession {
  let id: UUID
  let createdAt: Date

  private var manifest: RecordingRecoveryStore.Manifest
  private var sourceHandle: FileHandle?

  fileprivate init(id: UUID, createdAt: Date, manifest: RecordingRecoveryStore.Manifest, sourceHandle: FileHandle) {
    self.id = id
    self.createdAt = createdAt
    self.manifest = manifest
    self.sourceHandle = sourceHandle
  }

  func append(_ samples: UnsafeBufferPointer<Float>) throws {
    guard !samples.isEmpty else { return }
    guard manifest.state == .capturing, let sourceHandle else {
      throw RecordingRecoveryStore.Error.writeAfterSeal
    }

    let data = Data(bytes: samples.baseAddress!, count: samples.count * MemoryLayout<Float>.size)
    try sourceHandle.write(contentsOf: data)
    try sourceHandle.synchronize()

    // The raw file is authoritative: write and sync frames first, then publish their count.
    // A crash between these operations merely leaves an older count in the manifest; recovery
    // uses the physical frame count and retains those already-synced frames.
    manifest.frameCount += Int64(samples.count)
    try RecordingRecoveryStore.writeManifest(manifest)
  }

  func seal() throws {
    guard manifest.state == .capturing else { return }
    try sourceHandle?.synchronize()
    try sourceHandle?.close()
    sourceHandle = nil
    manifest.state = .sealed
    try RecordingRecoveryStore.writeManifest(manifest)
  }

  func finalize() throws -> RecoveredRecording {
    try seal()
    return try RecordingRecoveryStore.finalize(manifest: manifest)
  }

  func abandonForRecovery() {
    // Best effort only: append() already synchronizes each accepted buffer. Keep the source
    // even if sealing cannot complete so a later launch can still recover its valid prefix.
    try? seal()
    try? sourceHandle?.close()
    sourceHandle = nil
  }
}

struct RecoveredRecording: Equatable, Sendable {
  let sessionID: UUID
  let createdAt: Date
  let audioURL: URL
  let duration: TimeInterval
}

enum RecordingRecoveryStore {
  fileprivate enum Error: LocalizedError {
    case writeAfterSeal
    case invalidSource

    var errorDescription: String? {
      switch self {
      case .writeAfterSeal:
        "The recording source was already sealed."
      case .invalidSource:
        "The recording source is not a regular PCM file."
      }
    }
  }

  fileprivate enum State: String, Codable {
    case capturing
    case sealed
    case finalAudioReady
  }

  fileprivate struct Manifest: Codable {
    let version: Int
    let id: UUID
    let createdAt: Date
    let sampleRate: Double
    let channels: Int
    var frameCount: Int64
    var state: State
  }

  private static let logger = HexLog.recording
  private static let sampleRate = 16_000.0
  private static let channels = 1

  static func begin() throws -> RecordingRecoverySession {
    let id = UUID()
    let createdAt = Date()
    try createDirectories()

    let manifest = Manifest(
      version: 1,
      id: id,
      createdAt: createdAt,
      sampleRate: sampleRate,
      channels: channels,
      frameCount: 0,
      state: .capturing
    )
    try writeManifest(manifest)

    let sourceURL = sourceURL(for: id)
    FileManager.default.createFile(atPath: sourceURL.path, contents: nil)
    let sourceHandle = try FileHandle(forWritingTo: sourceURL)
    try sourceHandle.synchronize()
    return RecordingRecoverySession(id: id, createdAt: createdAt, manifest: manifest, sourceHandle: sourceHandle)
  }

  static func recoverInterruptedRecordings() -> [RecoveredRecording] {
    do {
      try createDirectories()
      let manifests = try FileManager.default.contentsOfDirectory(
        at: activeRecordingsDirectory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )

      return manifests.compactMap { manifestURL in
        guard manifestURL.pathExtension == "json",
              let id = UUID(uuidString: manifestURL.deletingPathExtension().lastPathComponent),
              isRegularFile(manifestURL),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.id == id,
              manifest.version == 1,
              manifest.sampleRate == sampleRate,
              manifest.channels == channels
        else {
          return nil
        }

        do {
          let recovered = try finalize(manifest: manifest)
          guard recovered.duration > 0 else {
            try? FileManager.default.removeItem(at: recovered.audioURL)
            releaseSource(for: recovered.sessionID)
            return nil
          }
          return recovered
        } catch {
          logger.error("Could not recover an interrupted recording: \(error.localizedDescription, privacy: .private)")
          return nil
        }
      }
    } catch {
      logger.error("Could not scan interrupted recordings: \(error.localizedDescription, privacy: .private)")
      return []
    }
  }

  static func releaseSource(for sessionID: UUID) {
    let sourceURL = sourceURL(for: sessionID)
    let manifestURL = manifestURL(for: sessionID)
    guard isExpectedPath(sourceURL, under: activeRecordingsDirectory),
          isExpectedPath(manifestURL, under: activeRecordingsDirectory)
    else { return }

    try? FileManager.default.removeItem(at: sourceURL)
    try? FileManager.default.removeItem(at: manifestURL)
  }

  static func releaseSource(forFinalAudioURL url: URL) {
    guard let sessionID = sessionID(forFinalAudioURL: url) else { return }
    releaseSource(for: sessionID)
  }

  static func sessionID(forFinalAudioURL url: URL) -> UUID? {
    guard isExpectedPath(url, under: recordingsDirectory),
          url.pathExtension == "wav"
    else { return nil }
    let prefix = "active-"
    let name = url.deletingPathExtension().lastPathComponent
    guard name.hasPrefix(prefix) else { return nil }
    return UUID(uuidString: String(name.dropFirst(prefix.count)))
  }

  fileprivate static func finalize(manifest: Manifest) throws -> RecoveredRecording {
    try createDirectories()
    let sourceURL = sourceURL(for: manifest.id)
    guard isRegularFile(sourceURL) else { throw Error.invalidSource }

    let finalURL = finalAudioURL(for: manifest.id)
    let sourceFrameCount = try physicalFrameCount(at: sourceURL)
    let usableFrameCount = min(sourceFrameCount, Int64(Int.max))
    guard usableFrameCount >= 0 else { throw Error.invalidSource }

    if !isRegularFile(finalURL) {
      let temporaryURL = recordingsDirectory.appendingPathComponent(".active-\(manifest.id.uuidString).partial.wav")
      try? FileManager.default.removeItem(at: temporaryURL)
      try writeWAV(from: sourceURL, frames: usableFrameCount, to: temporaryURL)
      try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
    }

    var completedManifest = manifest
    completedManifest.frameCount = usableFrameCount
    completedManifest.state = .finalAudioReady
    try writeManifest(completedManifest)
    return RecoveredRecording(
      sessionID: manifest.id,
      createdAt: manifest.createdAt,
      audioURL: finalURL,
      duration: Double(usableFrameCount) / sampleRate
    )
  }

  fileprivate static func writeManifest(_ manifest: Manifest) throws {
    try createDirectories()
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: manifestURL(for: manifest.id), options: .atomic)
  }

  private static func writeWAV(from sourceURL: URL, frames: Int64, to outputURL: URL) throws {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: AVAudioChannelCount(channels),
      interleaved: false
    )!
    let audioFile = try AVAudioFile(
      forWriting: outputURL,
      settings: [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: true,
      ],
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    let source = try FileHandle(forReadingFrom: sourceURL)
    defer { try? source.close() }
    var remainingFrames = frames
    let framesPerChunk = 16_384
    while remainingFrames > 0 {
      let framesThisChunk = min(Int64(framesPerChunk), remainingFrames)
      let byteCount = Int(framesThisChunk) * MemoryLayout<Float>.size
      guard let data = try source.read(upToCount: byteCount), data.count == byteCount,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesThisChunk)),
            let destination = buffer.floatChannelData?[0]
      else { throw Error.invalidSource }

      data.withUnsafeBytes { rawBuffer in
        destination.update(from: rawBuffer.bindMemory(to: Float.self).baseAddress!, count: Int(framesThisChunk))
      }
      buffer.frameLength = AVAudioFrameCount(framesThisChunk)
      try audioFile.write(from: buffer)
      remainingFrames -= framesThisChunk
    }
  }

  private static func physicalFrameCount(at sourceURL: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
    guard let byteCount = attributes[.size] as? NSNumber else { throw Error.invalidSource }
    return byteCount.int64Value / Int64(MemoryLayout<Float>.size)
  }

  private static func createDirectories() throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: activeRecordingsDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
  }

  private static var storageRoot: URL {
    if let root = try? URL.hexApplicationSupport {
      return root
    }
    logger.error("Falling back to the temporary directory for durable recording storage")
    return FileManager.default.temporaryDirectory.appendingPathComponent("io.github.blackforestboi.Octo", isDirectory: true)
  }

  private static var activeRecordingsDirectory: URL {
    storageRoot.appendingPathComponent("ActiveRecordings", isDirectory: true)
  }

  private static var recordingsDirectory: URL {
    storageRoot.appendingPathComponent("Recordings", isDirectory: true)
  }

  private static func sourceURL(for id: UUID) -> URL {
    activeRecordingsDirectory.appendingPathComponent("\(id.uuidString).pcm")
  }

  private static func manifestURL(for id: UUID) -> URL {
    activeRecordingsDirectory.appendingPathComponent("\(id.uuidString).json")
  }

  private static func finalAudioURL(for id: UUID) -> URL {
    recordingsDirectory.appendingPathComponent("active-\(id.uuidString).wav")
  }

  private static func isExpectedPath(_ url: URL, under directory: URL) -> Bool {
    url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    guard isExpectedPath(url, under: url.deletingLastPathComponent()),
          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }
}
