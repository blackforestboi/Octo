@preconcurrency import AVFoundation
import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

/// Parakeet v2 cannot use FluidAudio's prefix-suppressed final-window backfill.
/// Decode long recordings as overlapping, full-size windows instead so the
/// final inference window ends on the real recording boundary without being
/// dominated by model padding. No samples are added after the user's stop.
enum ParakeetV2LongFormTranscriber {
  struct DecodeResult {
    let output: TranscriptionOutput
    let windowCount: Int
    let fallbackMergeCount: Int
    let audioDuration: TimeInterval
    let finalTokenEnd: TimeInterval?
  }

  struct MergeResult {
    let tokens: [TokenTiming]
    let usedFallback: Bool
  }

  static let windowDuration: TimeInterval = 15
  static let minimumOverlapDuration: TimeInterval = 2
  private static let tokenTimeTolerance: TimeInterval = 0.64

  /// Returns full-size, evenly spaced windows whose first sample is zero and
  /// whose final sample is exactly the recording end. Adjacent windows overlap
  /// by at least `minimumOverlapDuration`.
  static func frameRanges(
    totalFrames: AVAudioFramePosition,
    sampleRate: Double
  ) -> [Range<AVAudioFramePosition>] {
    guard totalFrames > 0, sampleRate > 0 else { return [] }

    let windowFrames = AVAudioFramePosition((windowDuration * sampleRate).rounded(.down))
    let overlapFrames = AVAudioFramePosition((minimumOverlapDuration * sampleRate).rounded(.up))
    guard windowFrames > overlapFrames else { return [0..<totalFrames] }
    guard totalFrames > windowFrames else { return [0..<totalFrames] }

    let uncoveredFrames = totalFrames - windowFrames
    let maximumStride = windowFrames - overlapFrames
    let additionalWindowCount = Int(
      (uncoveredFrames + maximumStride - 1) / maximumStride
    )

    return (0...additionalWindowCount).map { index in
      let start: AVAudioFramePosition
      if index == additionalWindowCount {
        start = uncoveredFrames
      } else {
        start = uncoveredFrames * AVAudioFramePosition(index)
          / AVAudioFramePosition(additionalWindowCount)
      }
      return start..<(start + windowFrames)
    }
  }

  static func transcribe(
    _ url: URL,
    using asr: AsrManager
  ) async throws -> DecodeResult? {
    let audioFile = try AVAudioFile(forReading: url)
    let sampleRate = audioFile.processingFormat.sampleRate
    let ranges = frameRanges(totalFrames: audioFile.length, sampleRate: sampleRate)
    guard ranges.count > 1 else { return nil }

    let decoderLayers = await asr.decoderLayerCount
    var mergedTokens: [TokenTiming] = []
    var previousRange: Range<AVAudioFramePosition>?
    var fallbackMergeCount = 0

    for range in ranges {
      let frameCount = range.upperBound - range.lowerBound
      guard frameCount > 0, frameCount <= AVAudioFramePosition(AVAudioFrameCount.max),
        let buffer = AVAudioPCMBuffer(
          pcmFormat: audioFile.processingFormat,
          frameCapacity: AVAudioFrameCount(frameCount)
        )
      else {
        throw ParakeetV2LongFormError.bufferAllocationFailed
      }

      audioFile.framePosition = range.lowerBound
      try audioFile.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))

      var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
      let result = try await asr.transcribe(buffer, decoderState: &decoderState)
      guard let localTokens = result.tokenTimings else {
        throw ParakeetV2LongFormError.missingTokenTimings
      }

      let offset = TimeInterval(range.lowerBound) / sampleRate
      let absoluteTokens = localTokens.map { token in
        TokenTiming(
          token: token.token,
          tokenId: token.tokenId,
          startTime: token.startTime + offset,
          endTime: token.endTime + offset,
          confidence: token.confidence
        )
      }

      if let previousRange {
        let overlap = (
          start: TimeInterval(range.lowerBound) / sampleRate,
          end: TimeInterval(previousRange.upperBound) / sampleRate
        )
        let merge = merge(mergedTokens, absoluteTokens, overlap: overlap)
        mergedTokens = merge.tokens
        if merge.usedFallback { fallbackMergeCount += 1 }
      } else {
        mergedTokens = absoluteTokens
      }
      previousRange = range
    }

    let text = transcriptText(from: mergedTokens)
    let words = buildWordTimings(from: mergedTokens).map {
      TimedTranscriptWord(word: $0.word, startTime: $0.startTime, endTime: $0.endTime)
    }
    let duration = TimeInterval(audioFile.length) / sampleRate

    return DecodeResult(
      output: .init(text: text, words: words),
      windowCount: ranges.count,
      fallbackMergeCount: fallbackMergeCount,
      audioDuration: duration,
      finalTokenEnd: mergedTokens.last?.endTime
    )
  }

  /// Splice independently decoded windows on a matching token run inside the
  /// acoustic overlap. This removes the backfilled prefix while retaining all
  /// newly decoded audio through the final boundary.
  static func merge(
    _ existing: [TokenTiming],
    _ next: [TokenTiming],
    overlap: (start: TimeInterval, end: TimeInterval)
  ) -> MergeResult {
    guard !existing.isEmpty else { return .init(tokens: next, usedFallback: false) }
    guard !next.isEmpty else { return .init(tokens: existing, usedFallback: false) }

    let existingCandidates = existing.indices.filter {
      existing[$0].endTime >= overlap.start - tokenTimeTolerance
        && existing[$0].startTime <= overlap.end + tokenTimeTolerance
    }
    let nextCandidates = next.indices.filter {
      next[$0].endTime >= overlap.start - tokenTimeTolerance
        && next[$0].startTime <= overlap.end + tokenTimeTolerance
    }

    var bestMatch: (existingStart: Int, nextStart: Int, length: Int, endTime: TimeInterval)?
    for existingStart in existingCandidates {
      for nextStart in nextCandidates where existing[existingStart].tokenId == next[nextStart].tokenId {
        var length = 0
        while existingStart + length < existing.count,
          nextStart + length < next.count,
          existing[existingStart + length].tokenId == next[nextStart + length].tokenId,
          abs(existing[existingStart + length].startTime - next[nextStart + length].startTime)
            <= tokenTimeTolerance
        {
          length += 1
        }
        guard length >= 2 else { continue }

        let endTime = next[nextStart + length - 1].endTime
        // Prefer the earliest stable anchor. Everything after it comes from
        // the newer full window, so a word omitted near the previous window's
        // frontier is recovered instead of being hidden by a later match.
        if bestMatch == nil
          || endTime < bestMatch!.endTime
          || (endTime == bestMatch!.endTime && length > bestMatch!.length)
        {
          bestMatch = (existingStart, nextStart, length, endTime)
        }
      }
    }

    if let bestMatch {
      let retained = existing.prefix(bestMatch.existingStart + bestMatch.length)
      let appended = next.dropFirst(bestMatch.nextStart + bestMatch.length)
      return .init(
        tokens: removeAdjacentDuplicates(Array(retained) + appended),
        usedFallback: false
      )
    }

    // Recognition can legitimately differ across an overlap. If there is no
    // stable token anchor, splice at a word boundary nearest the overlap's
    // midpoint rather than inventing, padding, or forcing any tail words.
    let midpoint = (overlap.start + overlap.end) / 2
    let boundaryIndex = next.indices.min { lhs, rhs in
      let lhsPenalty = wordBoundaryPenalty(next[lhs])
      let rhsPenalty = wordBoundaryPenalty(next[rhs])
      if lhsPenalty != rhsPenalty { return lhsPenalty < rhsPenalty }
      return abs(next[lhs].startTime - midpoint) < abs(next[rhs].startTime - midpoint)
    } ?? next.startIndex
    let boundaryTime = next[boundaryIndex].startTime
    let retained = existing.prefix { $0.startTime < boundaryTime }
    return .init(
      tokens: removeAdjacentDuplicates(Array(retained) + next.dropFirst(boundaryIndex)),
      usedFallback: true
    )
  }

  static func transcriptText(from tokens: [TokenTiming]) -> String {
    tokens
      .filter { $0.token != "<blank>" && $0.token != "<pad>" }
      .map(\.token)
      .joined()
      .replacingOccurrences(of: "\u{2581}", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func wordBoundaryPenalty(_ token: TokenTiming) -> Int {
    token.token.hasPrefix(" ") || token.token.hasPrefix("\u{2581}") ? 0 : 1
  }

  private static func removeAdjacentDuplicates(_ tokens: [TokenTiming]) -> [TokenTiming] {
    var result: [TokenTiming] = []
    result.reserveCapacity(tokens.count)
    for token in tokens {
      if let previous = result.last,
        previous.tokenId == token.tokenId,
        abs(previous.startTime - token.startTime) <= tokenTimeTolerance
      {
        continue
      }
      result.append(token)
    }
    return result
  }
}

private enum ParakeetV2LongFormError: LocalizedError {
  case bufferAllocationFailed
  case missingTokenTimings

  var errorDescription: String? {
    switch self {
    case .bufferAllocationFailed:
      return "Unable to allocate a Parakeet v2 transcription window."
    case .missingTokenTimings:
      return "Parakeet v2 did not return token timings needed to merge transcription windows."
    }
  }
}
#endif
