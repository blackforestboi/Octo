import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

actor CoalescingAsyncCache<Key: Hashable & Sendable, Value: Sendable> {
  private var values: [Key: Value] = [:]
  private var tasks: [Key: Task<Value, Error>] = [:]

  func value(
    for key: Key,
    load: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    if let value = values[key] { return value }
    if let task = tasks[key] { return try await task.value }

    let task = Task { try await load() }
    tasks[key] = task
    do {
      let value = try await task.value
      values[key] = value
      tasks[key] = nil
      return value
    } catch {
      tasks[key] = nil
      throw error
    }
  }

  func removeValue(for key: Key) {
    tasks[key]?.cancel()
    tasks[key] = nil
    values[key] = nil
  }
}

actor ParakeetClient {
  static let shared = ParakeetClient()
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetModel?
  private let modelCache = CoalescingAsyncCache<ParakeetModel, AsrModels>()
  private let logger = HexLog.parakeet
  private let vendorDirs = [
    // Our app-specific cache path convention (under XDG or io.github.blackforestboi.Octo/cache)
    "fluidaudio/Models",
    "FluidAudio/Models"
  ]

  func isModelAvailable(_ modelName: String) async -> Bool {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      logger.error("Unknown Parakeet variant requested: \(modelName)")
      return false
    }
    if currentVariant == variant, asr != nil { return true }

    let directory = AsrModels.defaultCacheDirectory(for: variant.asrVersion)
    migrateLegacyCacheIfNeeded(variant, to: directory)
    let available = AsrModels.modelsExist(
      at: directory,
      version: variant.asrVersion
    )
    if available {
      logger.notice("Found Parakeet cache at \(directory.path)")
    } else {
      logger.debug("No Parakeet cache detected variant=\(variant.identifier) path=\(directory.path)")
    }
    return available
  }

  func ensureLoaded(
    modelName: String,
    progress: @escaping (Progress) -> Void,
    preparationPhase: @escaping (ModelPreparationPhase) -> Void = { _ in }
  ) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "Parakeet",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Parakeet variant: \(modelName)"]
      )
    }
    if currentVariant == variant, asr != nil { return }
    let t0 = Date()
    let models = try await loadModelAssets(for: variant, progress: progress)
    self.models = models
    preparationPhase(.activating)
    let manager = AsrManager(config: .init(), models: models)
    self.asr = manager
    self.currentVariant = variant
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 100
    progress(p)
    logger.notice("Parakeet ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  private func loadModelAssets(
    for variant: ParakeetModel,
    progress: @escaping (Progress) -> Void
  ) async throws -> AsrModels {
    let t0 = Date()
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)
    let directory = AsrModels.defaultCacheDirectory(for: variant.asrVersion)
    migrateLegacyCacheIfNeeded(variant, to: directory)
    logger.notice("Requesting Parakeet assets variant=\(variant.identifier)")
    let pollTask = Task {
      while p.completedUnitCount < 95 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let size = directorySize(directory) {
          let target: Double = 650 * 1024 * 1024
          let fraction = max(0.0, min(1.0, Double(size) / target))
          p.completedUnitCount = Int64(5 + fraction * 90)
          progress(p)
        }
        if Task.isCancelled { break }
      }
    }
    defer { pollTask.cancel() }
    let models = try await modelCache.value(for: variant) {
      try await AsrModels.downloadAndLoad(version: variant.asrVersion)
    }
    p.completedUnitCount = 100
    progress(p)
    logger.notice(
      "Parakeet assets ready variant=\(variant.identifier) elapsedSeconds=\(String(format: "%.2f", Date().timeIntervalSince(t0)))"
    )
    return models
  }

  private func directorySize(_ dir: URL) -> UInt64? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles) else { return nil }
    var total: UInt64 = 0
    for case let url as URL in en {
      if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
        total &+= UInt64(vals.fileSize ?? 0)
      }
    }
    return total
  }

  private func migrateLegacyCacheIfNeeded(_ variant: ParakeetModel, to directory: URL) {
    let legacyDirectory = directory
      .deletingLastPathComponent()
      .appendingPathComponent(variant.identifier, isDirectory: true)

    do {
      if try LegacyModelCacheMigrator.migrate(
        from: legacyDirectory,
        to: directory,
        isValid: {
          AsrModels.modelsExist(at: $0, version: variant.asrVersion)
        }
      ) {
        logger.notice("Migrated legacy Parakeet cache from \(legacyDirectory.path) to \(directory.path)")
      }
    } catch {
      logger.error("Failed to migrate legacy Parakeet cache: \(error.localizedDescription)")
    }
  }

  func transcribe(_ url: URL) async throws -> TranscriptionOutput {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    let t0 = Date()
    logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent)")

    if currentVariant == .englishV2,
      let endAligned = try await ParakeetV2LongFormTranscriber.transcribe(url, using: asr)
    {
      logger.notice(
        "Parakeet v2 end-aligned transcription windows=\(endAligned.windowCount) mergeFallbacks=\(endAligned.fallbackMergeCount) audioDuration=\(String(format: "%.3f", endAligned.audioDuration))s finalTokenEnd=\(String(format: "%.3f", endAligned.finalTokenEnd ?? 0))s"
      )
      logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
      return endAligned.output
    }

    var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let result = try await asr.transcribe(url, decoderState: &decoderState)
    logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    return .init(
      text: result.text,
      words: result.tokenTimings.map(buildWordTimings(from:)).map {
        $0.map { .init(word: $0.word, startTime: $0.startTime, endTime: $0.endTime) }
      } ?? []
    )
  }

  func loadedModels(
    modelName: String,
    progress: @escaping (Progress) -> Void = { _ in }
  ) async throws -> AsrModels {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "Parakeet",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Parakeet variant: \(modelName)"]
      )
    }
    return try await loadModelAssets(for: variant, progress: progress)
  }

  // Delete cached Parakeet models from known locations and reset state
  func deleteCaches(modelName: String) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else { return }
    let fm = FileManager.default

    var removedAny = false
    for dir in modelDirectories(variant) {
      if fm.fileExists(atPath: dir.path) {
        try? fm.removeItem(at: dir)
        removedAny = true
      }
    }

    // Reset live objects so a future download can proceed cleanly
    if removedAny {
      await modelCache.removeValue(for: variant)
      if currentVariant == variant {
        self.asr = nil
        self.models = nil
        currentVariant = nil
      }
    }
  }

  /// Returns all candidate directories where a Parakeet model might be cached.
  /// Includes both exact matches and prefixed directories (e.g. versioned folders).
  private func modelDirectories(_ variant: ParakeetModel) -> [URL] {
    let fm = FileManager.default
    var result: [URL] = [AsrModels.defaultCacheDirectory(for: variant.asrVersion)]

    for root in candidateRoots() {
      for vendor in vendorDirs {
        let base = root.appendingPathComponent(vendor, isDirectory: true)
        // Exact match directory
        let direct = base.appendingPathComponent(variant.identifier, isDirectory: true)
        result.append(direct)
        // Prefixed directories (e.g. versioned folders)
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
          for item in items where item.lastPathComponent.hasPrefix(variant.identifier) && item != direct {
            result.append(item)
          }
        }
      }
    }
    var seen = Set<String>()
    return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  private func candidateRoots() -> [URL] {
    let fm = FileManager.default
    let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
    let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let preferredAppSupport = try? URL.hexApplicationSupportRoot
    let appCache = try? URL.hexApplicationSupport.appendingPathComponent("cache", isDirectory: true)
    let userCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)
    return [xdg, appCache, appSupport, preferredAppSupport, userCache].compactMap { $0 }
  }
}

private extension ParakeetModel {
  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2: return .v2
    case .multilingualV3: return .v3
    }
  }
}

#else

actor ParakeetClient {
  static let shared = ParakeetClient()
  func isModelAvailable(_ modelName: String) async -> Bool { false }
  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "Parakeet",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Parakeet support not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to Octo."]
    )
  }
  func transcribe(_ url: URL) async throws -> TranscriptionOutput { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
  func deleteCaches(modelName: String) async throws {}
}

#endif
