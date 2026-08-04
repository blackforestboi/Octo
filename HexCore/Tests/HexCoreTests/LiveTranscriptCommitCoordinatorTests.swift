import Foundation
import Testing
@testable import HexCore

struct LiveTranscriptCommitCoordinatorTests {
	@Test
	func stableOverlappingWordsCommitExactlyOnce() {
		let take = UUID()
		var coordinator = LiveTranscriptCommitCoordinator(
			mode: .highAccuracyFour,
			takeGeneration: take,
			targetDelay: 0
		)
		let words = [TimedTranscriptWord(word: "Hello.", startTime: 0, endTime: 1)]

		#expect(coordinator.ingest(hypothesis(take: take, generation: 1, words: words, through: 1)) == nil)
		let commit = coordinator.ingest(hypothesis(take: take, generation: 2, words: words, through: 1))
		#expect(commit?.sections.map(\.text) == ["Hello."])
		#expect(commit?.sections.first?.commitSequence == 1)
		#expect(coordinator.ingest(hypothesis(take: take, generation: 3, words: words, through: 1)) == nil)
	}

	@Test
	func fractionalWordEndAtSampleFrontierBecomesVisible() {
		let take = UUID()
		var coordinator = LiveTranscriptCommitCoordinator(
			mode: .highAccuracyFour,
			takeGeneration: take,
			targetDelay: 0
		)
		let fractionalEnd = 1.000_000_01
		let words = [TimedTranscriptWord(
			word: "Visible.",
			startTime: 0,
			endTime: fractionalEnd
		)]

		#expect(coordinator.ingest(hypothesis(
			take: take,
			generation: 1,
			words: words,
			through: fractionalEnd
		)) == nil)
		let commit = coordinator.ingest(hypothesis(
			take: take,
			generation: 2,
			words: words,
			through: fractionalEnd
		))

		#expect(commit?.sections.map(\.text) == ["Visible."])
		#expect(commit?.checkpoint.lastCommitSequence == 1)
	}

	@Test
	func volatileAndOutOfOrderGenerationsCannotCommit() {
		let take = UUID()
		var coordinator = LiveTranscriptCommitCoordinator(
			mode: .highAccuracyFour,
			takeGeneration: take,
			targetDelay: 0
		)
		let first = [TimedTranscriptWord(word: "Hello.", startTime: 0, endTime: 1)]
		let changed = [TimedTranscriptWord(word: "Yellow.", startTime: 0, endTime: 1)]

		#expect(coordinator.ingest(hypothesis(take: take, generation: 2, words: first, through: 1)) == nil)
		#expect(coordinator.ingest(hypothesis(take: take, generation: 1, words: first, through: 1)) == nil)
		#expect(coordinator.ingest(hypothesis(take: take, generation: 3, words: changed, through: 1)) == nil)
		#expect(coordinator.checkpoint.lastCommitSequence == 0)
	}

	@Test
	func silenceAdvancesWithoutCreatingASection() {
		let take = UUID()
		var coordinator = LiveTranscriptCommitCoordinator(
			mode: .highAccuracyFour,
			takeGeneration: take,
			targetDelay: 0
		)

		let commit = coordinator.ingest(hypothesis(
			take: take,
			generation: 1,
			words: [],
			through: 12,
			containsSpeech: false
		))

		#expect(commit?.sections.isEmpty == true)
		#expect(coordinator.checkpoint.sources[.microphone]?.committedThroughSample == 12 * 16_000)
	}

	@Test
	func unresolvedHealthySpeechBecomesUnclearAtTwentySeconds() {
		let take = UUID()
		var coordinator = LiveTranscriptCommitCoordinator(
			mode: .highAccuracyFour,
			takeGeneration: take,
			targetDelay: 8,
			ambiguityLimit: 20
		)

		let commit = coordinator.ingest(hypothesis(
			take: take,
			generation: 1,
			words: [],
			through: 20,
			containsSpeech: true
		))

		#expect(commit?.sections.first?.text == "[unclear]")
		#expect(commit?.sections.first?.fragmentKind == .unclear)
	}

	@Test
	func silenceAfterUnclearSpeechAdvancesWithoutRepeatingTheFragment() {
		let take = UUID()
		var coordinator = LiveTranscriptCommitCoordinator(
			mode: .highAccuracyFour,
			takeGeneration: take,
			targetDelay: 8,
			ambiguityLimit: 20
		)
		let unresolved = LiveTranscriptionHypothesis(
			source: .microphone,
			takeGeneration: take,
			generation: 1,
			words: [],
			isProviderConfirmed: true,
			containsSpeech: true,
			processedThrough: 20,
			speechObservedThrough: 1
		)
		#expect(coordinator.ingest(unresolved)?.sections.map(\.text) == ["[unclear]"])

		var laterSilence = unresolved
		laterSilence.generation = 2
		laterSilence.processedThrough = 30
		let silenceCommit = coordinator.ingest(laterSilence)
		#expect(silenceCommit?.sections.isEmpty == true)
		#expect(coordinator.checkpoint.sources[.microphone]?.committedThroughSample == 22 * 16_000)
	}

	@Test
	func stableTextWithUnsafeSpeakerAttributionUsesUnknownSpeaker() {
		let take = UUID()
		var coordinator = LiveTranscriptCommitCoordinator(
			mode: .highAccuracyFour,
			takeGeneration: take,
			targetDelay: 0
		)
		let words = [TimedTranscriptWord(word: "Hello.", startTime: 0, endTime: 1)]

		_ = coordinator.ingest(hypothesis(
			take: take,
			generation: 1,
			words: words,
			through: 1,
			requiresSpeakerAttribution: true
		))
		let commit = coordinator.ingest(hypothesis(
			take: take,
			generation: 2,
			words: words,
			through: 1,
			requiresSpeakerAttribution: true
		))

		#expect(commit?.sections.first?.speakerName == "Unknown speaker")
		#expect(commit?.sections.first?.sessionSpeakerID == nil)
	}

	@Test
	func twoSourceOutputWaitsForTheMinimumSafeFrontier() {
		let take = UUID()
		let checkpoint = LiveTranscriptCheckpoint(
			sources: [.microphone: .init(), .systemAudio: .init()],
			takeGeneration: take
		)
		var coordinator = LiveTranscriptCommitCoordinator(
			mode: .highAccuracyFour,
			takeGeneration: take,
			targetDelay: 0,
			checkpoint: checkpoint
		)
		let words = [TimedTranscriptWord(word: "Mic.", startTime: 0, endTime: 1)]

		_ = coordinator.ingest(hypothesis(take: take, generation: 1, words: words, through: 1))
		let blocked = coordinator.ingest(hypothesis(take: take, generation: 2, words: words, through: 1))
		#expect(blocked?.sections.isEmpty == true)

		let released = coordinator.ingest(hypothesis(
			take: take,
			source: .systemAudio,
			generation: 1,
			words: [],
			through: 1,
			containsSpeech: false
		))
		#expect(released?.sections.map(\.text) == ["Mic."])
	}

	@Test
	func fourSpeakerCapacityFailsClosed() {
		assertSpeakerCapacity(mode: .highAccuracyFour, capacity: 4)
	}

	@Test
	func tenSpeakerCapacityFailsClosed() {
		assertSpeakerCapacity(mode: .moreSpeakersTen, capacity: 10)
	}

	private func assertSpeakerCapacity(mode: SpeakerDiarizationMode, capacity: Int) {
		let take = UUID()
		var coordinator = LiveTranscriptCommitCoordinator(
			mode: mode,
			takeGeneration: take,
			targetDelay: 0
		)
		var words = [TimedTranscriptWord]()
		var segments = [SpeakerDiarizationSegment]()
		var committed = [TimestampedTranscriptSection]()
		var generation = 0

		for speakerIndex in 0...capacity {
			let start = TimeInterval(speakerIndex)
			let end = start + 0.8
			words.append(.init(word: "S\(speakerIndex).", startTime: start, endTime: end))
			segments.append(.init(
				speakerID: "slot-\(speakerIndex)",
				embedding: [],
				startTime: start,
				endTime: end,
				qualityScore: 1
			))
			for _ in 0..<2 {
				generation += 1
				let hypothesis = LiveTranscriptionHypothesis(
					source: .microphone,
					takeGeneration: take,
					generation: generation,
					words: words,
					isProviderConfirmed: true,
					containsSpeech: true,
					requiresSpeakerAttribution: true,
					processedThrough: end,
					diarization: .init(segments: segments)
				)
				committed.append(contentsOf: coordinator.ingest(hypothesis)?.sections ?? [])
			}
		}

		#expect(coordinator.sessionSpeakers.count == capacity)
		#expect(committed.dropLast().allSatisfy { $0.sessionSpeakerID != nil })
		#expect(committed.last?.sessionSpeakerID == nil)
		#expect(committed.last?.speakerName == "Unknown speaker")
	}

	private func hypothesis(
		take: UUID,
		source: TranscriptAudioSource = .microphone,
		generation: Int,
		words: [TimedTranscriptWord],
		through: TimeInterval,
		containsSpeech: Bool = true,
		requiresSpeakerAttribution: Bool = false
	) -> LiveTranscriptionHypothesis {
		.init(
			source: source,
			takeGeneration: take,
			generation: generation,
			words: words,
			isProviderConfirmed: true,
			containsSpeech: containsSpeech,
			requiresSpeakerAttribution: requiresSpeakerAttribution,
			processedThrough: through
		)
	}
}
