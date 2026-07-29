import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// Uses the configured refinement model to distinguish an actual self-introduction
/// from ordinary first-person speech before a new voice profile is created.
@DependencyClient
struct SpeakerIntroductionClient {
	var classify: @Sendable ([SpeakerIntroductionContext], HexSettings) async throws -> [SpeakerIntroduction]
}

extension SpeakerIntroductionClient: DependencyKey {
	static var liveValue: Self {
		@Dependency(\.refinement) var refinement
		return Self(
			classify: { contexts, settings in
				guard !contexts.isEmpty else { return [] }
				let sourceText = contexts
					.map { "[\($0.speakerID)]\n\($0.text)" }
					.joined(separator: "\n\n")
				let output = try await refinement.refine(
					settings.refinementRequest(for: sourceText, mode: .speakerIntroduction)
				)
				return SpeakerIntroductionResponse.decode(output, allowedSpeakerIDs: Set(contexts.map(\.speakerID)))
			}
		)
	}
}

extension DependencyValues {
	var speakerIntroduction: SpeakerIntroductionClient {
		get { self[SpeakerIntroductionClient.self] }
		set { self[SpeakerIntroductionClient.self] = newValue }
	}
}

private enum SpeakerIntroductionResponse {
	private struct Entry: Decodable {
		let speakerID: String
		let name: String
	}

	static func decode(_ output: String, allowedSpeakerIDs: Set<String>) -> [SpeakerIntroduction] {
		let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
		let json = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "` "))
		guard let data = json.data(using: .utf8),
			let entries = try? JSONDecoder().decode([Entry].self, from: data)
		else { return [] }

		return entries.compactMap { entry in
			guard allowedSpeakerIDs.contains(entry.speakerID), let name = validName(entry.name) else { return nil }
			return .init(speakerID: entry.speakerID, name: name)
		}
	}

	private static func validName(_ value: String) -> String? {
		let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
		let words = name.split(whereSeparator: \.isWhitespace)
		guard name.count >= 2, name.count <= 60, (1...3).contains(words.count) else { return nil }
		guard words.allSatisfy({ word in
			word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" || $0 == "–" }
		}) else { return nil }
		return words.joined(separator: " ").capitalized(with: .current)
	}
}
