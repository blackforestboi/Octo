import Foundation

private let speakerIdentificationLogger = HexLog.transcription

/// The engine that turns an audio recording into anonymous, timed speaker turns.
///
/// Keep this separate from the transcription model: an ASR provider can supply
/// its own diarization data later without changing the feature's consumers.
public enum SpeakerDiarizationProvider: String, Codable, CaseIterable, Equatable, Sendable {
	case fluidAudio

	public var displayName: String {
		switch self {
		case .fluidAudio: "FluidAudio"
		}
	}
}

/// A word recognized by an ASR provider together with its location in the source audio.
public struct TimedTranscriptWord: Codable, Equatable, Sendable {
	public var word: String
	public var startTime: TimeInterval
	public var endTime: TimeInterval

	public init(word: String, startTime: TimeInterval, endTime: TimeInterval) {
		self.word = word
		self.startTime = startTime
		self.endTime = endTime
	}
}

/// A complete sentence recognised locally together with its span in the source audio.
///
/// This is deliberately independent of speaker attribution: every timing-capable ASR
/// provider can create these sections, while diarization remains optional enrichment.
public struct TimestampedTranscriptSection: Codable, Equatable, Sendable, Identifiable {
	public var id: UUID
	public var text: String
	public var startTime: TimeInterval
	public var endTime: TimeInterval
	/// The originating audio stream when a recording captured more than one source.
	public var audioSource: TranscriptAudioSource?
	/// A speaker label takes precedence over the audio-source label in History.
	public var speakerName: String?

	public init(
		id: UUID = UUID(),
		text: String,
		startTime: TimeInterval,
		endTime: TimeInterval,
		audioSource: TranscriptAudioSource? = nil,
		speakerName: String? = nil
	) {
		self.id = id
		self.text = text
		self.startTime = startTime
		self.endTime = endTime
		self.audioSource = audioSource
		self.speakerName = speakerName
	}

	public var displayLabel: String? { speakerName ?? audioSource?.displayName }
}

/// Pure conversion between timed ASR words and the sentence-sized representation used
/// by History, paste, and refinement.
public enum TimestampedTranscriptSectionBuilder {
	public static func sections(from words: [TimedTranscriptWord]) -> [TimestampedTranscriptSection] {
		var result = [TimestampedTranscriptSection]()
		var currentWords = [TimedTranscriptWord]()

		func appendCurrentSection() {
			guard let first = currentWords.first, let last = currentWords.last else { return }
			let text = renderedText(from: currentWords)
			guard !text.isEmpty else { return }
			result.append(.init(text: text, startTime: first.startTime, endTime: last.endTime))
		}

		for word in words {
			guard !word.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
			currentWords.append(word)
			if endsSentence(word.word) {
				appendCurrentSection()
				currentWords = []
			}
		}
		appendCurrentSection()
		return result
	}

	public static func renderedText(from sections: [TimestampedTranscriptSection]) -> String {
		sections
			.map(\.text)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}

	private static func endsSentence(_ text: String) -> Bool {
		let terminal = text
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'”’)]}"))
		guard let last = terminal.last else { return false }
		return ".!?…".contains(last)
	}

	private static func renderedText(from words: [TimedTranscriptWord]) -> String {
		words.reduce(into: "") { result, word in
			let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !token.isEmpty else { return }
			if result.isEmpty || token.allSatisfy({ ".,!?;:)]}”.’".contains($0) }) {
				result.append(token)
			} else {
				result.append(" ")
				result.append(token)
			}
		}
	}
}

/// Provider-neutral ASR output. Providers that do not expose timestamps can return
/// an empty `words` array; speaker attribution then safely leaves their text alone.
public struct TranscriptionOutput: Codable, Equatable, Sendable {
	public var text: String
	public var words: [TimedTranscriptWord]
	public var timestampedSections: [TimestampedTranscriptSection]
	public var canonicalText: String {
		let sectionText = TimestampedTranscriptSectionBuilder.renderedText(from: timestampedSections)
		return sectionText.isEmpty ? text : sectionText
	}
	/// Optional anonymous speaker turns supplied directly by an ASR provider. When
	/// present, Octo skips its separate diarization provider and only performs the
	/// local name/profile matching pass.
	public var diarization: SpeakerDiarizationOutput?
	/// Optional provider-neutral speaker turns added after transcription. This lets
	/// a future ASR provider return diarization itself while preserving the same
	/// result consumed by the feature.
	public var speakerAttribution: SpeakerAttributedTranscript?

	public init(
		text: String,
		words: [TimedTranscriptWord] = [],
		timestampedSections: [TimestampedTranscriptSection] = [],
		diarization: SpeakerDiarizationOutput? = nil,
		speakerAttribution: SpeakerAttributedTranscript? = nil
	) {
		self.text = text
		self.words = words
		self.timestampedSections = timestampedSections.isEmpty
			? TimestampedTranscriptSectionBuilder.sections(from: words)
			: timestampedSections
		self.diarization = diarization
		self.speakerAttribution = speakerAttribution
	}
}

/// A contiguous portion of audio associated with one diarizer speaker track.
public struct SpeakerDiarizationSegment: Codable, Equatable, Sendable {
	public var speakerID: String
	public var embedding: [Float]
	public var startTime: TimeInterval
	public var endTime: TimeInterval
	public var qualityScore: Float
	/// A saved profile enrolled directly into the diarizer for this speaker slot.
	/// This is stronger evidence than comparing post-hoc cluster centroids.
	public var profileID: UUID?

	public init(
		speakerID: String,
		embedding: [Float],
		startTime: TimeInterval,
		endTime: TimeInterval,
		qualityScore: Float,
		profileID: UUID? = nil
	) {
		self.speakerID = speakerID
		self.embedding = embedding
		self.startTime = startTime
		self.endTime = endTime
		self.qualityScore = qualityScore
		self.profileID = profileID
	}
}

/// The only diarization shape the rest of Octo depends on.
///
/// Keeping FluidAudio types out of this model makes a future embedded ASR+diarization
/// model, or a different local diarizer, a provider implementation rather than a
/// feature rewrite.
public struct SpeakerDiarizationOutput: Codable, Equatable, Sendable {
	public var segments: [SpeakerDiarizationSegment]

	public init(segments: [SpeakerDiarizationSegment]) {
		self.segments = segments
	}
}

/// A short, local-only clip that lets a person recognize a saved voice profile.
public struct SpeakerVoiceSample: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var audioURL: URL
	public var duration: TimeInterval
	public var createdAt: Date
	/// Identifies how the clip boundaries were chosen. Optional keeps samples
	/// written by earlier app versions decodable so they can be refreshed later.
	public var extractionVersion: Int?

	public init(
		id: UUID = UUID(),
		audioURL: URL,
		duration: TimeInterval,
		createdAt: Date = .now,
		extractionVersion: Int? = nil
	) {
		self.id = id
		self.audioURL = audioURL
		self.duration = duration
		self.createdAt = createdAt
		self.extractionVersion = extractionVersion
	}
}

/// A user-approved local voice profile. The embedding is a voiceprint-like numeric
/// representation and the samples are short, independent local audio clips.
public struct SpeakerVoiceProfile: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String
	public var embedding: [Float]
	/// Set when the user renames a profile in Settings, so later introductions do
	/// not silently undo their chosen label. Optional keeps older profiles decodable.
	public var isNameUserEdited: Bool?
	/// One playable local recording that makes a profile recognizable in Settings.
	/// Optional keeps profiles saved by earlier app versions decodable.
	public var audioSamples: [SpeakerVoiceSample]?
	public var createdAt: Date
	public var lastSeenAt: Date

	public var isUnknownSpeaker: Bool {
		guard isNameUserEdited != true else { return false }
		let prefix = "Unknown Speaker "
		guard name.hasPrefix(prefix) else { return false }
		let number = name.dropFirst(prefix.count)
		return !number.isEmpty && number.allSatisfy(\.isNumber)
	}

	public init(
		id: UUID = UUID(),
		name: String,
		embedding: [Float],
		isNameUserEdited: Bool? = nil,
		audioSamples: [SpeakerVoiceSample]? = nil,
		createdAt: Date = .now,
		lastSeenAt: Date = .now
	) {
		self.id = id
		self.name = name
		self.embedding = embedding
		self.isNameUserEdited = isNameUserEdited
		self.audioSamples = audioSamples
		self.createdAt = createdAt
		self.lastSeenAt = lastSeenAt
	}
}

/// The persisted, local-only library used as a fallback when a speaker does not
/// introduce themself in the current recording.
public struct SpeakerVoiceLibrary: Codable, Equatable, Sendable {
	public var profiles: [SpeakerVoiceProfile]

	public init(profiles: [SpeakerVoiceProfile] = []) {
		self.profiles = profiles
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		profiles = try container.decodeIfPresent([SpeakerVoiceProfile].self, forKey: .profiles) ?? []
		for index in profiles.indices {
			guard profiles[index].isNameUserEdited != true,
				let number = Self.legacyUnnamedSpeakerNumber(from: profiles[index].name)
			else { continue }
			profiles[index].name = "Unknown Speaker \(number)"
		}
	}

	private static func legacyUnnamedSpeakerNumber(from name: String) -> String? {
		let prefix = "Speaker "
		guard name.hasPrefix(prefix) else { return nil }
		let number = String(name.dropFirst(prefix.count))
		guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
		return number
	}
}

/// A semantic decision from the configured language model that a diarized speaker
/// has genuinely introduced themself by name.
public struct SpeakerIntroduction: Codable, Equatable, Sendable {
	public var speakerID: String
	public var name: String

	public init(speakerID: String, name: String) {
		self.speakerID = speakerID
		self.name = name
	}
}

/// The per-speaker transcript context supplied to the introduction classifier.
public struct SpeakerIntroductionContext: Equatable, Sendable {
	public var speakerID: String
	public var text: String

	public init(speakerID: String, text: String) {
		self.speakerID = speakerID
		self.text = text
	}
}

/// A speaker-labelled transcript turn retained with History and used for rendering.
public struct SpeakerAttributedSegment: Codable, Equatable, Sendable, Identifiable {
	public var id: UUID
	public var speakerID: String
	/// The stable local library entry when this turn was matched to a known voice.
	public var profileID: UUID?
	public var speakerName: String
	public var text: String
	public var startTime: TimeInterval
	public var endTime: TimeInterval

	public init(
		id: UUID = UUID(),
		speakerID: String,
		profileID: UUID? = nil,
		speakerName: String,
		text: String,
		startTime: TimeInterval,
		endTime: TimeInterval
	) {
		self.id = id
		self.speakerID = speakerID
		self.profileID = profileID
		self.speakerName = speakerName
		self.text = text
		self.startTime = startTime
		self.endTime = endTime
	}
}

/// The result of matching ASR timestamps with anonymous diarization turns.
public struct SpeakerAttributedTranscript: Codable, Equatable, Sendable {
	public var segments: [SpeakerAttributedSegment]

	public init(segments: [SpeakerAttributedSegment]) {
		self.segments = segments
	}

	public var renderedText: String {
		segments
			.map { "\($0.speakerName): \($0.text)" }
			.joined(separator: "\n\n")
	}
}

/// Pure, provider-independent speaker recognition and transcript attribution.
public enum SpeakerIdentification {
	public static let selfIntroductionWindow: TimeInterval = 20
	public static let maximumAudioSamples = 1

	public static func attribute(
		transcription: TranscriptionOutput,
		diarization: SpeakerDiarizationOutput,
		library: inout SpeakerVoiceLibrary,
		now: Date,
		introductions: [SpeakerIntroduction] = [],
		audioSource: TranscriptAudioSource? = nil
	) -> SpeakerAttributedTranscript? {
		guard !transcription.words.isEmpty, !diarization.segments.isEmpty else { return nil }

		let diarizedSpeakerIDs = Dictionary(grouping: diarization.segments, by: \.speakerID)
			.sorted { lhs, rhs in
				(lhs.value.map(\.startTime).min() ?? 0) < (rhs.value.map(\.startTime).min() ?? 0)
			}
			.map(\.key)

		let orderedWords = transcription.words.sorted { $0.startTime < $1.startTime }
		let wordsBySpeaker = Dictionary(grouping: orderedWords.compactMap { word -> (String, TimedTranscriptWord)? in
			guard let speakerID = speakerID(for: word, segments: diarization.segments) else { return nil }
			return (speakerID, word)
		}, by: \.0)
		let orderedSpeakerIDs = diarizedSpeakerIDs.filter { !(wordsBySpeaker[$0] ?? []).isEmpty }
		guard !orderedSpeakerIDs.isEmpty else { return nil }

		var displayNames = [String: String]()
		var profileIDs = [String: UUID]()
		let introducedNames = Dictionary(
			introductions.map { ($0.speakerID, $0.name) },
			uniquingKeysWith: { first, _ in first }
		)
		let embeddingsBySpeaker = Dictionary(uniqueKeysWithValues: orderedSpeakerIDs.map { speakerID in
			let speakerSegments = diarization.segments.filter { $0.speakerID == speakerID }
			return (speakerID, averageEmbedding(from: speakerSegments.map(\.embedding)))
		})
		let savedProfiles = library
		let enrolledProfileIDs: [String: UUID] = Dictionary(
			uniqueKeysWithValues: orderedSpeakerIDs.compactMap { speakerID -> (String, UUID)? in
			let profileIDs = Set(diarization.segments
				.filter { $0.speakerID == speakerID }
				.compactMap(\.profileID))
			guard profileIDs.count == 1, let profileID = profileIDs.first else { return nil }
			return (speakerID, profileID)
			}
		)
		for (index, speakerID) in orderedSpeakerIDs.enumerated() {
			let embedding = embeddingsBySpeaker[speakerID, default: []]

			// Known identities come only from immutable audio enrolled into the diarizer.
			// Never merge profiles or mutate a saved fingerprint after its first capture.
			if let profileID = enrolledProfileIDs[speakerID],
				let profile = savedProfiles.profiles.first(where: { $0.id == profileID })
			{
				displayNames[speakerID] = profile.name
				profileIDs[speakerID] = profile.id
				speakerIdentificationLogger.notice(
					"Speaker profile assigned source=\(audioSource?.rawValue ?? "unspecified", privacy: .public) speaker=\(speakerID, privacy: .public) profile=\(profile.id.uuidString, privacy: .public) method=sortformerEnrollment profileUpdated=false fingerprintUpdated=false"
				)
			} else {
				let name = introducedNames[speakerID] ?? "Unknown Speaker \(index + 1)"
				let profile = createProfile(named: name, embedding: embedding, library: &library, now: now)
				displayNames[speakerID] = profile.name
				profileIDs[speakerID] = profile.id
				speakerIdentificationLogger.notice(
					"Speaker profile created source=\(audioSource?.rawValue ?? "unspecified", privacy: .public) speaker=\(speakerID, privacy: .public) profile=\(profile.id.uuidString, privacy: .public) introduced=\(introducedNames[speakerID] != nil) embeddingDimensions=\(embedding.count)"
				)
			}
		}

		let labelledWords = orderedWords.compactMap { word -> (speakerID: String, word: TimedTranscriptWord)? in
			guard let speakerID = speakerID(for: word, segments: diarization.segments) else { return nil }
			return (speakerID, word)
		}
		guard !labelledWords.isEmpty else { return nil }

		var attributed = [SpeakerAttributedSegment]()
		var currentSpeakerID: String?
		var currentWords = [TimedTranscriptWord]()

		func appendCurrentSegment() {
			guard let currentSpeakerID, let first = currentWords.first, let last = currentWords.last else { return }
			let text = renderedText(from: currentWords)
			guard !text.isEmpty else { return }
			attributed.append(.init(
				speakerID: currentSpeakerID,
				profileID: profileIDs[currentSpeakerID],
				speakerName: displayNames[currentSpeakerID] ?? "Speaker",
				text: text,
				startTime: first.startTime,
				endTime: last.endTime
			))
		}

		for labelledWord in labelledWords {
			if let currentSpeakerID, currentSpeakerID != labelledWord.speakerID {
				appendCurrentSegment()
				currentWords = []
			}
			currentSpeakerID = labelledWord.speakerID
			currentWords.append(labelledWord.word)
		}
		appendCurrentSegment()

		return attributed.isEmpty ? nil : .init(segments: attributed)
	}

	public static func introductionContexts(
		transcription: TranscriptionOutput,
		diarization: SpeakerDiarizationOutput
	) -> [SpeakerIntroductionContext] {
		guard !transcription.words.isEmpty, !diarization.segments.isEmpty else { return [] }
		let speakerIDs = Dictionary(grouping: diarization.segments, by: \.speakerID)
			.sorted { lhs, rhs in
				(lhs.value.map(\.startTime).min() ?? 0) < (rhs.value.map(\.startTime).min() ?? 0)
			}
			.map(\.key)
		let wordsBySpeaker = Dictionary(grouping: transcription.words.compactMap { word -> (String, TimedTranscriptWord)? in
			guard let speakerID = speakerID(for: word, segments: diarization.segments) else { return nil }
			return (speakerID, word)
		}, by: \.0)

		return speakerIDs.compactMap { speakerID in
			guard let firstStart = diarization.segments
				.filter({ $0.speakerID == speakerID })
				.map(\.startTime)
				.min()
			else { return nil }
			let text = renderedText(from: wordsBySpeaker[speakerID, default: []]
				.map(\.1)
				.filter { $0.startTime < firstStart + selfIntroductionWindow })
			guard !text.isEmpty else { return nil }
			return .init(speakerID: speakerID, text: text)
		}
	}

	private static func speakerID(
		for word: TimedTranscriptWord,
		segments: [SpeakerDiarizationSegment]
	) -> String? {
		segments
			.map { segment -> (speakerID: String, overlap: TimeInterval) in
				let overlap = max(0, min(word.endTime, segment.endTime) - max(word.startTime, segment.startTime))
				return (segment.speakerID, overlap)
			}
			.max { $0.overlap < $1.overlap }
			.flatMap { $0.overlap > 0 ? $0.speakerID : nil }
	}

	private static func createProfile(
		named name: String,
		embedding: [Float],
		library: inout SpeakerVoiceLibrary,
		now: Date
	) -> SpeakerVoiceProfile {
		let profile = SpeakerVoiceProfile(
			name: name,
			embedding: embedding,
			isNameUserEdited: false,
			createdAt: now,
			lastSeenAt: now
		)
		library.profiles.append(profile)
		return profile
	}

	private static func averageEmbedding(from embeddings: [[Float]]) -> [Float] {
		guard let first = embeddings.first, !first.isEmpty else { return [] }
		let compatible = embeddings
			.filter { $0.count == first.count }
			.map { embedding in
				// JSONEncoder rejects NaN and infinity, which would otherwise drop the
				// entire voice library after a correctly detected introduction.
				embedding.map { $0.isFinite ? $0 : 0 }
			}
		guard !compatible.isEmpty else { return [] }
		let average = (0..<first.count).map { index in
			compatible.map { $0[index] }.reduce(0, +) / Float(compatible.count)
		}
		guard average.allSatisfy(\.isFinite) else { return [] }
		return average
	}

	private static func renderedText(from words: [TimedTranscriptWord]) -> String {
		words.reduce(into: "") { result, word in
			let token = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !token.isEmpty else { return }
			if result.isEmpty || token.allSatisfy({ ".,!?;:)]}".contains($0) }) {
				result.append(token)
			} else {
				result.append(" ")
				result.append(token)
			}
		}
	}
}
