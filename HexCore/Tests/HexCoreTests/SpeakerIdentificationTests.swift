import XCTest
@testable import HexCore

final class SpeakerIdentificationTests: XCTestCase {
	func testTimedWordsBuildTimestampedSentenceSectionsAndCanonicalText() {
		let output = TranscriptionOutput(
			text: "ignored provider text",
			words: [
				.init(word: "Hello", startTime: 0, endTime: 0.2),
				.init(word: "world.", startTime: 0.2, endTime: 0.5),
				.init(word: "How", startTime: 0.8, endTime: 1),
				.init(word: "are", startTime: 1, endTime: 1.2),
				.init(word: "you?", startTime: 1.2, endTime: 1.5),
				.init(word: "Fine", startTime: 1.8, endTime: 2),
			]
		)

		XCTAssertEqual(output.timestampedSections.map(\.text), ["Hello world.", "How are you?", "Fine"])
		XCTAssertEqual(output.timestampedSections.map(\.startTime), [0, 0.8, 1.8])
		XCTAssertEqual(output.timestampedSections.map(\.endTime), [0.5, 1.5, 2])
		XCTAssertEqual(output.canonicalText, "Hello world. How are you? Fine")
	}

	func testTimingFreeOutputKeepsProviderText() {
		let output = TranscriptionOutput(text: "Provider text")

		XCTAssertTrue(output.timestampedSections.isEmpty)
		XCTAssertEqual(output.canonicalText, "Provider text")
	}

	func testProviderTimestampedSectionsAreCanonicalWhenWordTimingsAreUnavailable() {
		let output = TranscriptionOutput(
			text: "Provider text",
			timestampedSections: [
				.init(text: "First sentence.", startTime: 0, endTime: 1),
				.init(text: "Second sentence.", startTime: 1.2, endTime: 2),
			]
		)

		XCTAssertEqual(output.canonicalText, "First sentence. Second sentence.")
	}

	func testIntroductionCreatesLocalVoiceProfileAndLabelsTurns() {
		let output = TranscriptionOutput(
			text: "My name is Natty. Welcome everyone.",
			words: [
				.init(word: "My", startTime: 0, endTime: 0.2),
				.init(word: "name", startTime: 0.2, endTime: 0.4),
				.init(word: "is", startTime: 0.4, endTime: 0.6),
				.init(word: "Natty.", startTime: 0.6, endTime: 0.9),
				.init(word: "Welcome", startTime: 1, endTime: 1.3),
				.init(word: "everyone.", startTime: 1.3, endTime: 1.7),
			]
		)
		let diarization = SpeakerDiarizationOutput(segments: [
			.init(speakerID: "speaker-0", embedding: [1, 0], startTime: 0, endTime: 2, qualityScore: 1),
		])
		var library = SpeakerVoiceLibrary()

		let attributed = SpeakerIdentification.attribute(
			transcription: output,
			diarization: diarization,
			library: &library,
			now: Date(timeIntervalSince1970: 1),
			introductions: [.init(speakerID: "speaker-0", name: "Natty")]
		)

		XCTAssertEqual(attributed?.segments.map(\.speakerName), ["Natty"])
		XCTAssertEqual(attributed?.renderedText, "Natty: My name is Natty. Welcome everyone.")
		XCTAssertEqual(library.profiles.map(\.name), ["Natty"])
		XCTAssertEqual(attributed?.segments.first?.profileID, library.profiles[0].id)
	}

	func testKnownVoiceLabelsFutureRecordingWithoutAnIntroduction() {
		let output = TranscriptionOutput(
			text: "Thanks for joining.",
			words: [
				.init(word: "Thanks", startTime: 0, endTime: 0.3),
				.init(word: "for", startTime: 0.3, endTime: 0.5),
				.init(word: "joining.", startTime: 0.5, endTime: 0.9),
			]
		)
		let diarization = SpeakerDiarizationOutput(segments: [
			.init(speakerID: "speaker-7", embedding: [0.99, 0.01], startTime: 0, endTime: 1, qualityScore: 1),
		])
		var library = SpeakerVoiceLibrary(profiles: [
			.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Natty", embedding: [1, 0], createdAt: .distantPast, lastSeenAt: .distantPast),
		])

		let attributed = SpeakerIdentification.attribute(
			transcription: output,
			diarization: diarization,
			library: &library,
			now: Date(timeIntervalSince1970: 2)
		)

		XCTAssertEqual(attributed?.segments.map(\.speakerName), ["Natty"])
		XCTAssertEqual(library.profiles[0].lastSeenAt, Date(timeIntervalSince1970: 2))
		XCTAssertEqual(attributed?.segments.first?.profileID, library.profiles[0].id)
	}

	func testModerateVoiceSimilarityMatchesAStoredProfile() {
		let output = TranscriptionOutput(
			text: "Thanks for joining.",
			words: [
				.init(word: "Thanks", startTime: 0, endTime: 0.3),
				.init(word: "for", startTime: 0.3, endTime: 0.5),
				.init(word: "joining.", startTime: 0.5, endTime: 0.9),
			]
		)
		let diarization = SpeakerDiarizationOutput(segments: [
			.init(speakerID: "speaker-0", embedding: [0.79, 0.613], startTime: 0, endTime: 1, qualityScore: 1),
		])
		var library = SpeakerVoiceLibrary(profiles: [
			.init(name: "Natty", embedding: [1, 0]),
		])

		let attributed = SpeakerIdentification.attribute(
			transcription: output,
			diarization: diarization,
			library: &library,
			now: .now
		)

		XCTAssertEqual(attributed?.segments.map(\.speakerName), ["Natty"])
	}

	func testMatchedTurnsCarryProfileIDForAudioSamples() {
		let output = TranscriptionOutput(
			text: "My name is Natty. Other. First example. Other. Second example. Other. Third example. Other. Fourth example.",
			words: [
				.init(word: "My", startTime: 0, endTime: 0.2),
				.init(word: "name", startTime: 0.2, endTime: 0.4),
				.init(word: "is", startTime: 0.4, endTime: 0.6),
				.init(word: "Natty.", startTime: 0.6, endTime: 0.8),
				.init(word: "Other.", startTime: 1, endTime: 1.4),
				.init(word: "First", startTime: 2, endTime: 2.3),
				.init(word: "example.", startTime: 2.3, endTime: 2.7),
				.init(word: "Other.", startTime: 3, endTime: 3.4),
				.init(word: "Second", startTime: 4, endTime: 4.3),
				.init(word: "example.", startTime: 4.3, endTime: 4.7),
				.init(word: "Other.", startTime: 5, endTime: 5.4),
				.init(word: "Third", startTime: 6, endTime: 6.3),
				.init(word: "example.", startTime: 6.3, endTime: 6.7),
				.init(word: "Other.", startTime: 7, endTime: 7.4),
				.init(word: "Fourth", startTime: 8, endTime: 8.3),
				.init(word: "example.", startTime: 8.3, endTime: 8.7),
			]
		)
		let diarization = SpeakerDiarizationOutput(segments: [
			.init(speakerID: "natty", embedding: [1, 0], startTime: 0, endTime: 1, qualityScore: 1),
			.init(speakerID: "other", embedding: [0, 1], startTime: 1, endTime: 2, qualityScore: 1),
			.init(speakerID: "natty", embedding: [1, 0], startTime: 2, endTime: 3, qualityScore: 1),
			.init(speakerID: "other", embedding: [0, 1], startTime: 3, endTime: 4, qualityScore: 1),
			.init(speakerID: "natty", embedding: [1, 0], startTime: 4, endTime: 5, qualityScore: 1),
			.init(speakerID: "other", embedding: [0, 1], startTime: 5, endTime: 6, qualityScore: 1),
			.init(speakerID: "natty", embedding: [1, 0], startTime: 6, endTime: 7, qualityScore: 1),
			.init(speakerID: "other", embedding: [0, 1], startTime: 7, endTime: 8, qualityScore: 1),
			.init(speakerID: "natty", embedding: [1, 0], startTime: 8, endTime: 9, qualityScore: 1),
		])
		var library = SpeakerVoiceLibrary()

		let attributed = SpeakerIdentification.attribute(
			transcription: output,
			diarization: diarization,
			library: &library,
			now: .now,
			introductions: [.init(speakerID: "natty", name: "Natty")]
		)

		let nattyProfileIDs = attributed?.segments
			.filter { $0.speakerName == "Natty" }
			.compactMap(\.profileID)
		XCTAssertEqual(Set(nattyProfileIDs ?? []), Set([library.profiles[0].id]))
	}

	func testExistingVoiceMatchWinsOverAnIntroduction() {
		let output = TranscriptionOutput(
			text: "My name is Natty.",
			words: [
				.init(word: "My", startTime: 0, endTime: 0.2),
				.init(word: "name", startTime: 0.2, endTime: 0.4),
				.init(word: "is", startTime: 0.4, endTime: 0.6),
				.init(word: "Natty.", startTime: 0.6, endTime: 0.8),
			]
		)
		let diarization = SpeakerDiarizationOutput(segments: [
			.init(speakerID: "speaker-0", embedding: [1, 0], startTime: 0, endTime: 1, qualityScore: 1),
		])
		var library = SpeakerVoiceLibrary(profiles: [
			.init(name: "Richard", embedding: [1, 0]),
		])

		let attributed = SpeakerIdentification.attribute(
			transcription: output,
			diarization: diarization,
			library: &library,
			now: .now,
			introductions: [.init(speakerID: "speaker-0", name: "Natty")]
		)

		XCTAssertEqual(attributed?.segments.map(\.speakerName), ["Richard"])
		XCTAssertEqual(library.profiles.map(\.name), ["Richard"])
	}

	func testCasualImPhraseDoesNotCreateAProfile() {
		let output = TranscriptionOutput(
			text: "I'm imagining hitting like control one.",
			words: [
				.init(word: "I'm", startTime: 0, endTime: 0.2),
				.init(word: "imagining", startTime: 0.2, endTime: 0.6),
				.init(word: "hitting", startTime: 0.6, endTime: 0.9),
				.init(word: "like", startTime: 0.9, endTime: 1.1),
				.init(word: "control", startTime: 1.1, endTime: 1.4),
				.init(word: "one.", startTime: 1.4, endTime: 1.7),
			]
		)
		let diarization = SpeakerDiarizationOutput(segments: [
			.init(speakerID: "speaker-0", embedding: [1, 0], startTime: 0, endTime: 2, qualityScore: 1),
		])
		var library = SpeakerVoiceLibrary()

		let attributed = SpeakerIdentification.attribute(
			transcription: output,
			diarization: diarization,
			library: &library,
			now: .now
		)

		XCTAssertEqual(attributed?.segments.map(\.speakerName), ["Speaker 1"])
		XCTAssertTrue(library.profiles.isEmpty)
	}

	func testCasualIAmPhraseDoesNotCreateAProfile() {
		let output = TranscriptionOutput(
			text: "I am thinking about the next action.",
			words: [
				.init(word: "I", startTime: 0, endTime: 0.1),
				.init(word: "am", startTime: 0.1, endTime: 0.2),
				.init(word: "thinking", startTime: 0.2, endTime: 0.5),
				.init(word: "about", startTime: 0.5, endTime: 0.7),
				.init(word: "the", startTime: 0.7, endTime: 0.8),
				.init(word: "next", startTime: 0.8, endTime: 1),
				.init(word: "action.", startTime: 1, endTime: 1.3),
			]
		)
		let diarization = SpeakerDiarizationOutput(segments: [
			.init(speakerID: "speaker-0", embedding: [1, 0], startTime: 0, endTime: 2, qualityScore: 1),
		])
		var library = SpeakerVoiceLibrary()

		_ = SpeakerIdentification.attribute(
			transcription: output,
			diarization: diarization,
			library: &library,
			now: .now
		)

		XCTAssertTrue(library.profiles.isEmpty)
	}

	func testUnalignedWordsDoNotCreateAnAttributionOrProfile() {
		let output = TranscriptionOutput(
			text: "My name is Natty.",
			words: [.init(word: "Natty.", startTime: 10, endTime: 11)]
		)
		let diarization = SpeakerDiarizationOutput(segments: [
			.init(speakerID: "speaker-0", embedding: [1, 0], startTime: 0, endTime: 1, qualityScore: 1),
		])
		var library = SpeakerVoiceLibrary()

		let attributed = SpeakerIdentification.attribute(
			transcription: output,
			diarization: diarization,
			library: &library,
			now: .now
		)

		XCTAssertNil(attributed)
		XCTAssertTrue(library.profiles.isEmpty)
	}
}
