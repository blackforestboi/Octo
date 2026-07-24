import Foundation
import Testing
@testable import HexCore

struct TranscriptionHistoryTests {
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
