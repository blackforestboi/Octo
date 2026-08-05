import Foundation
import HexCore
import XCTest

@testable import Octo

final class HistorySearchTests: XCTestCase {
	func testSearchMatchesTranscriptOnly() {
		let transcriptMatch = makeTranscript(text: "Generated result", rawText: "Spoken phrase")
		let outputMatch = makeTranscript(text: "Generated result", rawText: "Unrelated input")
		let metadataOnly = makeTranscript(text: "Unrelated output", rawText: "Unrelated input")
		var metadataTranscript = metadataOnly
		metadataTranscript.selectedText = "Spoken phrase"

		let matchingIDs = HistorySearch.matchingIDs(
			in: [transcriptMatch, outputMatch, metadataTranscript],
			query: "spoken"
		)

		XCTAssertEqual(matchingIDs, [transcriptMatch.id])
	}

	func testSearchMatchesGeneratedOutput() {
		let outputMatch = makeTranscript(text: "Generated result", rawText: "Unrelated input")
		let nonMatch = makeTranscript(text: "Unrelated output", rawText: "Unrelated input")

		let matchingIDs = HistorySearch.matchingIDs(in: [outputMatch, nonMatch], query: "generated")

		XCTAssertEqual(matchingIDs, [outputMatch.id])
	}

	func testSearchIsCaseInsensitiveAndExcludesRefinementSources() {
		let matchingRun = makeTranscript(text: "The final answer", rawText: "Raw text")
		var refinementSource = makeTranscript(text: "THE FINAL ANSWER", rawText: nil)
		refinementSource.isRefinementSource = true

		let matchingIDs = HistorySearch.matchingIDs(
			in: [matchingRun, refinementSource],
			query: "FINAL"
		)

		XCTAssertEqual(matchingIDs, [matchingRun.id])
	}

	func testRecordingSessionTakesBecomeOneHistoryEntry() {
		let sessionID = UUID()
		var newestTake = makeTranscript(text: "Second take", rawText: nil)
		newestTake.timestamp = Date(timeIntervalSince1970: 2)
		newestTake.recordingSessionID = sessionID
		newestTake.recordingSessionTitle = "Planning Session"
		var oldestTake = makeTranscript(text: "First take", rawText: nil)
		oldestTake.timestamp = Date(timeIntervalSince1970: 1)
		oldestTake.recordingSessionID = sessionID
		oldestTake.recordingSessionTitle = "Planning Session"
		let ordinaryRun = makeTranscript(text: "Ordinary run", rawText: nil)

		let entries = HistoryListEntry.grouped(from: [newestTake, oldestTake, ordinaryRun])

		XCTAssertEqual(entries.count, 2)
		guard case let .recordingSession(id, title, takes) = entries[0] else {
			return XCTFail("Expected the first entry to be the recording session")
		}
		XCTAssertEqual(id, sessionID)
		XCTAssertEqual(title, "Planning Session")
		XCTAssertEqual(takes.map(\.id), [newestTake.id, oldestTake.id])
		XCTAssertEqual(entries[1], .transcript(ordinaryRun))
	}

	func testSearchMatchKeepsTheWholeRecordingSessionTogether() {
		let sessionID = UUID()
		var matchingTake = makeTranscript(text: "Launch plan", rawText: nil)
		matchingTake.recordingSessionID = sessionID
		var siblingTake = makeTranscript(text: "Unrelated words", rawText: nil)
		siblingTake.recordingSessionID = sessionID

		let entries = HistoryListEntry.grouped(
			from: [matchingTake, siblingTake],
			matchingTranscriptIDs: [matchingTake.id]
		)

		guard case let .recordingSession(_, _, takes) = entries.first else {
			return XCTFail("Expected the matching session to remain grouped")
		}
		XCTAssertEqual(Set(takes.map(\.id)), Set([matchingTake.id, siblingTake.id]))
	}

	private func makeTranscript(text: String, rawText: String?) -> Transcript {
		Transcript(
			timestamp: Date(),
			text: text,
			audioPath: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).caf"),
			duration: 0,
			rawText: rawText
		)
	}
}
