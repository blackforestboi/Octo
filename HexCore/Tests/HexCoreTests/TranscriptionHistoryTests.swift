import Foundation
import Testing
@testable import HexCore

struct TranscriptionHistoryTests {
	@Test
	func legacyTranscriptDecodesWithoutTimestampedSections() throws {
		let legacyData = Data(
			#"{"id":"00000000-0000-0000-0000-000000000001","timestamp":0,"text":"legacy transcript","audioPath":"file:///legacy.wav","duration":1}"#.utf8
		)

		let transcript = try JSONDecoder().decode(Transcript.self, from: legacyData)

		#expect(transcript.timestampedSections == nil)
		#expect(transcript.audioChannels == nil)
	}

	@Test
	func audioChannelsRoundTripSeparatelyWithTheirTimelineLabels() throws {
		let microphone = TranscriptAudioChannel(
			source: .microphone,
			audioPath: URL(fileURLWithPath: "/mic.wav"),
			duration: 4,
			text: "Hello",
			timestampedSections: [.init(text: "Hello", startTime: 0, endTime: 1, audioSource: .microphone)]
		)
		let systemAudio = TranscriptAudioChannel(
			source: .systemAudio,
			audioPath: URL(fileURLWithPath: "/system.m4a"),
			duration: 4,
			text: "Welcome",
			timestampedSections: [.init(text: "Welcome", startTime: 0.5, endTime: 1.5, audioSource: .systemAudio)]
		)
		let transcript = Transcript(
			timestamp: .now,
			text: "Hello Welcome",
			audioPath: microphone.audioPath,
			duration: 4,
			audioChannels: [microphone, systemAudio]
		)

		let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))

		#expect(decoded.audioChannels == [microphone, systemAudio])
		#expect(decoded.audioChannels?[0].timestampedSections?.first?.displayLabel == "Microphone")
		#expect(decoded.audioChannels?[1].timestampedSections?.first?.displayLabel == "System Audio")
	}

	@Test
	func latestPasteableTranscriptUsesNewestTimestamp() {
		let oldTranscript = Transcript(
			timestamp: Date(timeIntervalSince1970: 1),
			text: "old transcript",
			audioPath: URL(fileURLWithPath: "/old.wav"),
			duration: 1
		)
		let newestTranscript = Transcript(
			timestamp: Date(timeIntervalSince1970: 3),
			text: "new transcript",
			audioPath: URL(fileURLWithPath: "/new.wav"),
			duration: 1
		)
		let recoveredTranscript = Transcript(
			timestamp: Date(timeIntervalSince1970: 4),
			text: "recovered audio",
			audioPath: URL(fileURLWithPath: "/recovered.wav"),
			duration: 1,
			recoverySessionID: UUID()
		)

		let history = TranscriptionHistory(history: [oldTranscript, recoveredTranscript, newestTranscript])

		#expect(history.latestPasteableTranscriptText == "new transcript")
	}
}
