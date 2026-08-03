import AVFoundation
import XCTest

@testable import Octo

#if canImport(FluidAudio)
import FluidAudio

final class ParakeetV2LongFormTranscriberTests: XCTestCase {
  func testShortClipUsesSingleExactRange() {
    let ranges = ParakeetV2LongFormTranscriber.frameRanges(
      totalFrames: 160_000,
      sampleRate: 16_000
    )

    XCTAssertEqual(ranges, [0..<160_000])
  }

  func testLongClipUsesFullWindowsEndingAtExactAudioBoundary() {
    let totalFrames: AVAudioFramePosition = 16_000 * 61 + 317
    let ranges = ParakeetV2LongFormTranscriber.frameRanges(
      totalFrames: totalFrames,
      sampleRate: 16_000
    )

    XCTAssertEqual(ranges.first?.lowerBound, 0)
    XCTAssertEqual(ranges.last?.upperBound, totalFrames)
    XCTAssertTrue(ranges.allSatisfy { $0.count == 16_000 * 15 })

    for pair in zip(ranges, ranges.dropFirst()) {
      let overlap = pair.0.upperBound - pair.1.lowerBound
      XCTAssertGreaterThanOrEqual(overlap, 16_000 * 2)
    }
  }

  func testOneSampleBeyondWindowStillEndsOnExactBoundaryWithoutPadding() {
    let totalFrames: AVAudioFramePosition = 16_000 * 15 + 1
    let ranges = ParakeetV2LongFormTranscriber.frameRanges(
      totalFrames: totalFrames,
      sampleRate: 16_000
    )

    XCTAssertEqual(ranges, [0..<240_000, 1..<240_001])
  }

  func testMatchingOverlapKeepsExistingPrefixAndNewTail() {
    let existing = [
      token(" before", id: 1, at: 12.0),
      token(" shared", id: 2, at: 13.1),
      token(" phrase", id: 3, at: 13.5),
    ]
    let next = [
      token(" shared", id: 2, at: 13.2),
      token(" phrase", id: 3, at: 13.6),
      token(" captured", id: 4, at: 14.3),
      token(" tail", id: 5, at: 15.2),
    ]

    let result = ParakeetV2LongFormTranscriber.merge(
      existing,
      next,
      overlap: (start: 13, end: 15)
    )

    XCTAssertFalse(result.usedFallback)
    XCTAssertEqual(result.tokens.map(\.tokenId), [1, 2, 3, 4, 5])
    XCTAssertEqual(
      ParakeetV2LongFormTranscriber.transcriptText(from: result.tokens),
      "before shared phrase captured tail"
    )
  }

  func testEarlierOverlapAnchorRecoversTokenMissingFromPreviousFrontier() {
    let existing = [
      token(" shared", id: 1, at: 13.0),
      token(" anchor", id: 2, at: 13.2),
      token(" later", id: 4, at: 14.0),
      token(" matching", id: 5, at: 14.2),
      token(" run", id: 6, at: 14.4),
    ]
    let next = [
      token(" shared", id: 1, at: 13.1),
      token(" anchor", id: 2, at: 13.3),
      token(" recovered", id: 3, at: 13.7),
      token(" later", id: 4, at: 14.1),
      token(" matching", id: 5, at: 14.3),
      token(" run", id: 6, at: 14.5),
      token(" tail", id: 7, at: 15.1),
    ]

    let result = ParakeetV2LongFormTranscriber.merge(
      existing,
      next,
      overlap: (start: 13, end: 15)
    )

    XCTAssertEqual(result.tokens.map(\.tokenId), [1, 2, 3, 4, 5, 6, 7])
  }

  private func token(_ text: String, id: Int, at time: TimeInterval) -> TokenTiming {
    TokenTiming(
      token: text,
      tokenId: id,
      startTime: time,
      endTime: time + 0.08,
      confidence: 1
    )
  }
}
#endif
