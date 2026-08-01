import Foundation
import HexCore
import XCTest

@testable import Octo

final class SpeakerVoiceSampleStoreTests: XCTestCase {
	func testSampleRangePreservesSpeechOutsideRecognizerWordBoundaries() throws {
		let range = try XCTUnwrap(SpeakerVoiceSampleStore.sampleRange(
			sourceDuration: 7.244,
			startTime: 0.88,
			endTime: 3.68
		))

		XCTAssertEqual(range.startTime, 0.38, accuracy: 0.000_001)
		XCTAssertEqual(range.endTime, 3.93, accuracy: 0.000_001)
		XCTAssertEqual(range.duration, 3.55, accuracy: 0.000_001)
	}

	func testSampleRangeUsesAvailableAudioAtRecordingEdges() throws {
		let range = try XCTUnwrap(SpeakerVoiceSampleStore.sampleRange(
			sourceDuration: 3.68,
			startTime: 0.2,
			endTime: 3.68
		))

		XCTAssertEqual(range.startTime, 0, accuracy: 0.000_001)
		XCTAssertEqual(range.endTime, 3.68, accuracy: 0.000_001)
	}

	func testSampleRangeNeverTradesRecognizedSpeechForPadding() throws {
		let range = try XCTUnwrap(SpeakerVoiceSampleStore.sampleRange(
			sourceDuration: 30,
			startTime: 2,
			endTime: 13.7
		))

		XCTAssertEqual(range.startTime, 1.8, accuracy: 0.000_001)
		XCTAssertEqual(range.endTime, 13.8, accuracy: 0.000_001)
		XCTAssertEqual(range.duration, SpeakerVoiceSampleStore.maximumSampleDuration, accuracy: 0.000_001)
	}

	func testSampleRangeRejectsInvalidBoundaries() {
		XCTAssertNil(SpeakerVoiceSampleStore.sampleRange(
			sourceDuration: 5,
			startTime: 3,
			endTime: 2
		))
	}

	func testLegacySamplesDecodeWithoutExtractionVersion() throws {
		let sample = SpeakerVoiceSample(
			audioURL: URL(fileURLWithPath: "/tmp/voice.m4a"),
			duration: 2.88,
			extractionVersion: SpeakerVoiceSampleStore.currentExtractionVersion
		)
		let encoded = try JSONEncoder().encode(sample)
		var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "extractionVersion")
		let legacyData = try JSONSerialization.data(withJSONObject: object)

		let decoded = try JSONDecoder().decode(SpeakerVoiceSample.self, from: legacyData)

		XCTAssertNil(decoded.extractionVersion)
	}
}
