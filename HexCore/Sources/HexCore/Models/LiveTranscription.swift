import Foundation

public struct CapturedAudioChunk: Equatable, Sendable {
	public var source: TranscriptAudioSource
	public var takeGeneration: UUID
	public var sequence: Int
	public var startSample: Int64
	public var sampleRate: Double
	public var samples: [Float]
	public var discontinuityBefore: Bool

	public init(
		source: TranscriptAudioSource,
		takeGeneration: UUID,
		sequence: Int,
		startSample: Int64,
		sampleRate: Double = 16_000,
		samples: [Float],
		discontinuityBefore: Bool = false
	) {
		self.source = source
		self.takeGeneration = takeGeneration
		self.sequence = sequence
		self.startSample = startSample
		self.sampleRate = sampleRate
		self.samples = samples
		self.discontinuityBefore = discontinuityBefore
	}

	public var endSample: Int64 { startSample + Int64(samples.count) }
}

public struct SourceLiveTranscriptCheckpoint: Codable, Equatable, Sendable {
	public var committedThroughSample: Int64
	public var observedThroughSample: Int64

	public init(committedThroughSample: Int64 = 0, observedThroughSample: Int64 = 0) {
		self.committedThroughSample = committedThroughSample
		self.observedThroughSample = observedThroughSample
	}
}

public enum LiveTranscriptDrainState: String, Codable, Equatable, Sendable {
	case active
	case drainingForPause
	case drainingForStop
	case drained
	case failed
}

public struct LiveTranscriptCheckpoint: Codable, Equatable, Sendable {
	public var sources: [TranscriptAudioSource: SourceLiveTranscriptCheckpoint]
	public var globalDisplayThroughSample: Int64
	public var lastCommitSequence: Int
	public var takeGeneration: UUID
	public var drainState: LiveTranscriptDrainState

	public init(
		sources: [TranscriptAudioSource: SourceLiveTranscriptCheckpoint] = [:],
		globalDisplayThroughSample: Int64 = 0,
		lastCommitSequence: Int = 0,
		takeGeneration: UUID = UUID(),
		drainState: LiveTranscriptDrainState = .active
	) {
		self.sources = sources
		self.globalDisplayThroughSample = globalDisplayThroughSample
		self.lastCommitSequence = lastCommitSequence
		self.takeGeneration = takeGeneration
		self.drainState = drainState
	}
}

public struct LiveTranscriptionHypothesis: Equatable, Sendable {
	public var source: TranscriptAudioSource
	public var takeGeneration: UUID
	public var generation: Int
	public var words: [TimedTranscriptWord]
	public var isProviderConfirmed: Bool
	public var containsSpeech: Bool
	public var requiresSpeakerAttribution: Bool
	public var processedThrough: TimeInterval
	public var diarization: SpeakerDiarizationOutput?
	/// Furthest point with locally observed speech energy or model speech activity.
	/// This lets confirmed silence advance after an earlier unresolved utterance.
	public var speechObservedThrough: TimeInterval?

	public init(
		source: TranscriptAudioSource,
		takeGeneration: UUID,
		generation: Int,
		words: [TimedTranscriptWord],
		isProviderConfirmed: Bool,
		containsSpeech: Bool,
		requiresSpeakerAttribution: Bool = false,
		processedThrough: TimeInterval,
		diarization: SpeakerDiarizationOutput? = nil,
		speechObservedThrough: TimeInterval? = nil
	) {
		self.source = source
		self.takeGeneration = takeGeneration
		self.generation = generation
		self.words = words
		self.isProviderConfirmed = isProviderConfirmed
		self.containsSpeech = containsSpeech
		self.requiresSpeakerAttribution = requiresSpeakerAttribution
		self.processedThrough = processedThrough
		self.diarization = diarization
		self.speechObservedThrough = speechObservedThrough
	}
}

public struct LiveTranscriptCommit: Equatable, Sendable {
	public var sections: [TimestampedTranscriptSection]
	public var sessionSpeakers: [SessionSpeaker]
	public var speakerSegments: [TranscriptAudioSource: [SpeakerAttributedSegment]]
	public var checkpoint: LiveTranscriptCheckpoint

	public init(
		sections: [TimestampedTranscriptSection],
		sessionSpeakers: [SessionSpeaker],
		speakerSegments: [TranscriptAudioSource: [SpeakerAttributedSegment]] = [:],
		checkpoint: LiveTranscriptCheckpoint
	) {
		self.sections = sections
		self.sessionSpeakers = sessionSpeakers
		self.speakerSegments = speakerSegments
		self.checkpoint = checkpoint
	}

	public var isEmpty: Bool { sections.isEmpty }
}

/// Pure append-only state machine shared by live capture, drain, and recovery.
public struct LiveTranscriptCommitCoordinator: Equatable, Sendable {
	public static let sampleRate: Double = 16_000

	public var mode: SpeakerDiarizationMode
	public var targetDelay: TimeInterval
	public var ambiguityLimit: TimeInterval
	public private(set) var checkpoint: LiveTranscriptCheckpoint
	public private(set) var sessionSpeakers: [SessionSpeaker]

	private var previousHypotheses: [TranscriptAudioSource: LiveTranscriptionHypothesis]
	public private(set) var engineSpeakerIDs: [TranscriptAudioSource: [String: UUID]]
	private var pendingSections: [TranscriptAudioSource: [TimestampedTranscriptSection]]

	public init(
		mode: SpeakerDiarizationMode,
		takeGeneration: UUID = UUID(),
		targetDelay: TimeInterval = 8,
		ambiguityLimit: TimeInterval = 20,
		checkpoint: LiveTranscriptCheckpoint? = nil,
		sessionSpeakers: [SessionSpeaker] = [],
		engineSpeakerIDs: [TranscriptAudioSource: [String: UUID]] = [:]
	) {
		self.mode = mode
		self.targetDelay = targetDelay
		self.ambiguityLimit = ambiguityLimit
		self.checkpoint = checkpoint ?? .init(takeGeneration: takeGeneration)
		self.sessionSpeakers = sessionSpeakers
		self.previousHypotheses = [:]
		self.engineSpeakerIDs = engineSpeakerIDs
		self.pendingSections = [:]
	}

	public mutating func ingest(
		_ hypothesis: LiveTranscriptionHypothesis,
		isDraining: Bool = false
	) -> LiveTranscriptCommit? {
		guard hypothesis.takeGeneration == checkpoint.takeGeneration else { return nil }
		if let previous = previousHypotheses[hypothesis.source], hypothesis.generation <= previous.generation {
			return nil
		}

		let previous = previousHypotheses[hypothesis.source]
		previousHypotheses[hypothesis.source] = hypothesis

		var sourceCheckpoint = checkpoint.sources[hypothesis.source] ?? .init()
		sourceCheckpoint.observedThroughSample = max(
			sourceCheckpoint.observedThroughSample,
			Self.samples(for: hypothesis.processedThrough)
		)

		let committedThrough = Self.time(for: sourceCheckpoint.committedThroughSample)
		let normalCutoff = max(committedThrough, hypothesis.processedThrough - targetDelay)
		let eligibleCutoff = isDraining ? hypothesis.processedThrough : normalCutoff

		let speechObservedThrough = hypothesis.speechObservedThrough ?? hypothesis.processedThrough
		let hasUnresolvedSpeech = hypothesis.containsSpeech && speechObservedThrough > committedThrough
		guard hasUnresolvedSpeech else {
			sourceCheckpoint.committedThroughSample = max(
				sourceCheckpoint.committedThroughSample,
				Self.samples(for: eligibleCutoff)
			)
			checkpoint.sources[hypothesis.source] = sourceCheckpoint
			advanceGlobalFrontier()
			return LiveTranscriptCommit(
				sections: flushVisibleSections(),
				sessionSpeakers: sessionSpeakers,
				checkpoint: checkpoint
			)
		}

		let stableWords = stablePrefix(previous: previous, current: hypothesis)
			.filter { $0.endTime > committedThrough && $0.endTime <= eligibleCutoff }
		let stableSections = TimestampedTranscriptSectionBuilder.sections(from: stableWords)
		var sections = stableSections
		let ambiguityAge = hypothesis.processedThrough - committedThrough
		if !isDraining, ambiguityAge < ambiguityLimit,
			let last = sections.last,
			!endsAtNaturalBoundary(last.text),
			!hasStableUtteranceBoundary(
				after: last.endTime,
				previous: previous,
				current: hypothesis
			) {
			sections.removeLast()
		}

		if sections.isEmpty, ambiguityAge >= ambiguityLimit {
			if !stableSections.isEmpty {
				sections = stableSections
			} else {
				let forcedEnd = min(
					speechObservedThrough,
					min(hypothesis.processedThrough, committedThrough + ambiguityLimit)
				)
				sections = [.init(
					text: "[unclear]",
					startTime: committedThrough,
					endTime: forcedEnd,
					audioSource: hypothesis.source,
					fragmentKind: .unclear
				)]
			}
		}

		guard !sections.isEmpty else {
			checkpoint.sources[hypothesis.source] = sourceCheckpoint
			return nil
		}

		for index in sections.indices {
			sections[index].audioSource = hypothesis.source
			sections[index].fragmentKind = sections[index].fragmentKind ?? .speech
			let speaker = stableSpeaker(
				from: previous?.diarization,
				and: hypothesis.diarization,
				start: sections[index].startTime,
				end: sections[index].endTime,
				source: hypothesis.source
			)
			sections[index].sessionSpeakerID = speaker?.id
			sections[index].speakerName = speaker?.fallbackLabel
				?? (hypothesis.requiresSpeakerAttribution ? "Unknown speaker" : nil)
			checkpoint.lastCommitSequence += 1
			sections[index].commitSequence = checkpoint.lastCommitSequence
		}
		if let endTime = sections.map(\.endTime).max() {
			sourceCheckpoint.committedThroughSample = max(
				sourceCheckpoint.committedThroughSample,
				Self.samples(for: endTime)
			)
		}
		checkpoint.sources[hypothesis.source] = sourceCheckpoint
		advanceGlobalFrontier()
		pendingSections[hypothesis.source, default: []].append(contentsOf: sections)
		let visibleSections = flushVisibleSections()
		var attributedSegments = [TranscriptAudioSource: [SpeakerAttributedSegment]]()
		for section in visibleSections {
			guard let source = section.audioSource, section.speakerName != nil else { continue }
			let speaker = section.sessionSpeakerID.flatMap { id in
				sessionSpeakers.first(where: { $0.id == id })
			}
			attributedSegments[source, default: []].append(.init(
				speakerID: speaker?.id.uuidString ?? "unknown",
				profileID: speaker?.profileID,
				speakerName: section.speakerName ?? "Unknown speaker",
				text: section.text,
				startTime: section.startTime,
				endTime: section.endTime
			))
		}
		return LiveTranscriptCommit(
			sections: visibleSections,
			sessionSpeakers: sessionSpeakers,
			speakerSegments: attributedSegments,
			checkpoint: checkpoint
		)
	}

	public mutating func setDrainState(_ state: LiveTranscriptDrainState) {
		checkpoint.drainState = state
	}

	public mutating func removeSource(_ source: TranscriptAudioSource) {
		checkpoint.sources.removeValue(forKey: source)
		previousHypotheses.removeValue(forKey: source)
		pendingSections.removeValue(forKey: source)
		engineSpeakerIDs.removeValue(forKey: source)
		advanceGlobalFrontier()
	}

	private func stablePrefix(
		previous: LiveTranscriptionHypothesis?,
		current: LiveTranscriptionHypothesis
	) -> [TimedTranscriptWord] {
		guard current.isProviderConfirmed, let previous, previous.isProviderConfirmed else { return [] }
		var result = [TimedTranscriptWord]()
		var oldSearchStart = 0
		var foundOverlap = false
		for new in current.words {
			let match = previous.words.indices.dropFirst(oldSearchStart).first { index in
				let old = previous.words[index]
				return normalized(old.word) == normalized(new.word)
					&& abs(old.startTime - new.startTime) <= 0.35
					&& abs(old.endTime - new.endTime) <= 0.35
			}
			guard let match else {
				if foundOverlap { break }
				continue
			}
			foundOverlap = true
			oldSearchStart = match + 1
			result.append(new)
		}
		return result
	}

	private mutating func stableSpeaker(
		from previous: SpeakerDiarizationOutput?,
		and current: SpeakerDiarizationOutput?,
		start: TimeInterval,
		end: TimeInterval,
		source: TranscriptAudioSource
	) -> SessionSpeaker? {
		guard let old = coveringSegment(in: previous, start: start, end: end),
			let new = coveringSegment(in: current, start: start, end: end),
			old.speakerID == new.speakerID,
			old.profileID == new.profileID
		else { return nil }

		if let profileID = new.profileID,
			let existing = sessionSpeakers.first(where: { $0.profileID == profileID }) {
			engineSpeakerIDs[source, default: [:]][new.speakerID] = existing.id
			return existing
		}
		if let id = engineSpeakerIDs[source]?[new.speakerID],
			let index = sessionSpeakers.firstIndex(where: { $0.id == id }) {
			if sessionSpeakers[index].profileID == nil,
				sessionSpeakers[index].lastKnownProfileName == nil,
				let profileID = new.profileID {
				sessionSpeakers[index].profileID = profileID
			}
			return sessionSpeakers[index]
		}
		guard sessionSpeakers.count < mode.speakerCapacity else { return nil }
		let speaker = SessionSpeaker(
			fallbackLabel: SessionSpeaker.fallbackLabel(at: sessionSpeakers.count),
			profileID: new.profileID
		)
		sessionSpeakers.append(speaker)
		engineSpeakerIDs[source, default: [:]][new.speakerID] = speaker.id
		return speaker
	}

	private func coveringSegment(
		in output: SpeakerDiarizationOutput?,
		start: TimeInterval,
		end: TimeInterval
	) -> SpeakerDiarizationSegment? {
		guard let candidates = output?.segments.filter({ $0.startTime <= start && $0.endTime >= end }),
			candidates.count == 1
		else { return nil }
		return candidates[0]
	}

	private mutating func advanceGlobalFrontier() {
		guard !checkpoint.sources.isEmpty else { return }
		checkpoint.globalDisplayThroughSample = checkpoint.sources.values
			.map(\.committedThroughSample)
			.min() ?? checkpoint.globalDisplayThroughSample
	}

	private mutating func flushVisibleSections() -> [TimestampedTranscriptSection] {
		let visibleThroughSample = checkpoint.globalDisplayThroughSample
		var visible = [TimestampedTranscriptSection]()
		for source in pendingSections.keys {
			let sections = pendingSections[source] ?? []
			let split = sections.firstIndex(where: {
				Self.samples(for: $0.endTime) > visibleThroughSample
			}) ?? sections.endIndex
			visible.append(contentsOf: sections[..<split])
			pendingSections[source] = Array(sections[split...])
		}
		return visible.sorted {
			if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
			if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
			return ($0.audioSource?.rawValue ?? "") < ($1.audioSource?.rawValue ?? "")
		}
	}

	private func normalized(_ word: String) -> String {
		word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	private func endsAtNaturalBoundary(_ text: String) -> Bool {
		guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
		return ".!?…".contains(last)
	}

	private func hasStableUtteranceBoundary(
		after endTime: TimeInterval,
		previous: LiveTranscriptionHypothesis?,
		current: LiveTranscriptionHypothesis
	) -> Bool {
		guard let previous else { return false }
		let currentNext = current.words.first(where: { $0.startTime >= endTime + 0.05 })?.startTime
		let previousNext = previous.words.first(where: { $0.startTime >= endTime + 0.05 })?.startTime
		let currentGap = (currentNext ?? current.processedThrough) - endTime
		let previousGap = (previousNext ?? previous.processedThrough) - endTime
		if currentGap >= 0.7, previousGap >= 0.7 { return true }

		guard let oldBefore = speakerID(in: previous.diarization, at: max(0, endTime - 0.05)),
			let newBefore = speakerID(in: current.diarization, at: max(0, endTime - 0.05)),
			oldBefore == newBefore,
			let oldAfter = nextSpeakerID(in: previous.diarization, after: endTime),
			let newAfter = nextSpeakerID(in: current.diarization, after: endTime),
			oldAfter == newAfter
		else { return false }
		return oldBefore != oldAfter
	}

	private func speakerID(in output: SpeakerDiarizationOutput?, at time: TimeInterval) -> String? {
		let matches = output?.segments.filter { $0.startTime <= time && $0.endTime >= time } ?? []
		return matches.count == 1 ? matches[0].speakerID : nil
	}

	private func nextSpeakerID(
		in output: SpeakerDiarizationOutput?,
		after time: TimeInterval
	) -> String? {
		output?.segments
			.filter { $0.startTime >= time - 0.05 && $0.startTime <= time + 1.0 }
			.min(by: { $0.startTime < $1.startTime })?
			.speakerID
	}

	private static func samples(for time: TimeInterval) -> Int64 {
		Int64((max(0, time) * sampleRate).rounded(.down))
	}

	private static func time(for samples: Int64) -> TimeInterval {
		TimeInterval(samples) / sampleRate
	}
}
