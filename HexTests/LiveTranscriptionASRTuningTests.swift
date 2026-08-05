import HexCore
import XCTest

@testable import Octo

#if canImport(FluidAudio)
import FluidAudio

final class LiveTranscriptionASRTuningTests: XCTestCase {
	func testWordHistoryPreservesWordsThatLeaveTheSlidingWindow() {
		let firstWindow = [
			word("Does", 0.4, 0.7),
			word("the", 0.7, 0.9),
			word("first", 0.9, 1.2),
		]
		let correctedWindow = [
			word("Is", 0.4, 0.7),
			word("this", 0.7, 1.0),
			word("first", 1.0, 1.3),
			word("part", 1.3, 1.6),
		]
		let finalWindow = [
			word("part", 1.3, 1.6),
			word("not", 1.7, 1.9),
			word("get", 1.9, 2.1),
			word("taken?", 2.1, 2.5),
		]

		let corrected = LiveTranscriptionWordHistory.merging(firstWindow, with: correctedWindow)
		let completed = LiveTranscriptionWordHistory.merging(corrected, with: finalWindow)

		XCTAssertEqual(completed.map(\.word), ["Is", "this", "first", "part", "not", "get", "taken?"])
	}

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

	private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedTranscriptWord {
		TimedTranscriptWord(word: text, startTime: start, endTime: end)
	}
}
#endif
