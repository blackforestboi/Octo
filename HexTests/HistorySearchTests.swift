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
