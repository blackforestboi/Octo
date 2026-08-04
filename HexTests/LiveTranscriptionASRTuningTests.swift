import HexCore
import XCTest

@testable import Octo

#if canImport(FluidAudio)
import FluidAudio

final class LiveTranscriptionASRTuningTests: XCTestCase {
	func testOverlappingWindowsCanStabilizeWordsAtEightSecondFrontier() {
		let configuration = LiveTranscriptionASRTuning.configuration
		let stabilityDelay = 8.0

		XCTAssertLessThanOrEqual(
			configuration.chunkSeconds + configuration.rightContextSeconds,
			stabilityDelay
		)
		XCTAssertGreaterThanOrEqual(
			configuration.leftContextSeconds,
			stabilityDelay - configuration.rightContextSeconds
		)
		XCTAssertLessThanOrEqual(configuration.minContextForConfirmation, stabilityDelay)
		XCTAssertLessThanOrEqual(configuration.windowSamples, 15 * 16_000)
	}
}
#endif
