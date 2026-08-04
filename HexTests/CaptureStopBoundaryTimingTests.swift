import AVFoundation
import XCTest

@testable import Octo

final class CaptureStopBoundaryTimingTests: XCTestCase {
  func testPhysicalStopEventIsTranslatedIntoInputNodeTimeline() {
    let eventHostTime = AVAudioTime.hostTime(forSeconds: 10)

    let targetHostTime = SuperFastCaptureController.stopBoundaryHostTime(
      eventHostTime: eventHostTime,
      inputTimelineLatency: 0.037,
      postRollDuration: 0
    )

    XCTAssertEqual(
      targetHostTime,
      eventHostTime + AVAudioTime.hostTime(forSeconds: 0.037)
    )
  }

  func testConfiguredPostRollRemainsSeparateFromTimelineTranslation() {
    let eventHostTime = AVAudioTime.hostTime(forSeconds: 10)

    let targetHostTime = SuperFastCaptureController.stopBoundaryHostTime(
      eventHostTime: eventHostTime,
      inputTimelineLatency: 0.037,
      postRollDuration: 0.025
    )

    XCTAssertEqual(
      AVAudioTime.seconds(forHostTime: targetHostTime - eventHostTime),
      0.062,
      accuracy: 0.000_001
    )
  }

  func testNegativeLatencyAndPostRollCannotMoveBoundaryBeforeKeypress() {
    let eventHostTime = AVAudioTime.hostTime(forSeconds: 10)

    XCTAssertEqual(
      SuperFastCaptureController.stopBoundaryHostTime(
        eventHostTime: eventHostTime,
        inputTimelineLatency: -1,
        postRollDuration: -1
      ),
      eventHostTime
    )
  }
}
