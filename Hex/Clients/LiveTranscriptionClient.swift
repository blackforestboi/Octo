import AVFoundation
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
@_spi(Internals) import Sharing

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

private let liveTranscriptionLogger = HexLog.transcription

@DependencyClient
struct LiveHistoryPersistenceClient {
	var persist: @Sendable (TranscriptionHistory) throws -> Void
}

extension LiveHistoryPersistenceClient: DependencyKey {
	static var liveValue: Self {
		@Dependency(\.defaultFileStorage) var storage
		return Self(persist: { history in
			let data = try JSONEncoder().encode(history)
			try storage.save(data, .transcriptionHistoryURL)
		})
	}

	static var testValue: Self { liveValue }
}

extension DependencyValues {
	var liveHistoryPersistence: LiveHistoryPersistenceClient {
		get { self[LiveHistoryPersistenceClient.self] }
		set { self[LiveHistoryPersistenceClient.self] = newValue }
	}
}

struct LiveTranscriptionConfiguration: Equatable, Sendable {
	var modelName: String
	var sessionID: UUID
	var takeGeneration: UUID
	var sources: Set<TranscriptAudioSource>
	var speakerIdentificationEnabled: Bool
	var speakerMode: SpeakerDiarizationMode
	var profiles: [SpeakerVoiceProfile]
	var isRecovery = false
}

extension LiveTranscriptionConfiguration {
	static let defaultModelName = ParakeetModel.multilingualV3.identifier
}

enum LiveTranscriptionEvent: Equatable, Sendable {
	case hypothesis(LiveTranscriptionHypothesis)
	case backlog(TimeInterval)
	case sourceDiscontinuity(UUID, TranscriptAudioSource, Int64)
	case speakerWarning(UUID, TranscriptAudioSource, String)
	case drained(UUID)
	case failed(UUID, String)
}

@DependencyClient
struct LiveTranscriptionClient {
	var prepare: @Sendable (String, SpeakerDiarizationMode?) async throws -> Void
	var prepareSpeakerMode: @Sendable (SpeakerDiarizationMode) async throws -> Void
	var start: @Sendable (LiveTranscriptionConfiguration) async throws -> AsyncStream<LiveTranscriptionEvent>
	var sendAudio: @Sendable (CapturedAudioChunk) async throws -> Void
	var sendAudioFileTail: @Sendable (
		_ audioURL: URL,
		_ source: TranscriptAudioSource,
		_ takeGeneration: UUID,
		_ startOffset: TimeInterval,
		_ committedThroughSample: Int64
	) async throws -> Void
	var finish: @Sendable (_ takeGeneration: UUID, _ endsSession: Bool) async -> Void
	var cancel: @Sendable () async -> Void
}

extension LiveTranscriptionClient: DependencyKey {
	static var liveValue: Self {
		let live = LiveTranscriptionClientLive()
		return Self(
			prepare: { try await live.prepare(modelName: $0, speakerMode: $1) },
			prepareSpeakerMode: { try await live.prepareSpeakerMode($0) },
			start: { try await live.start($0) },
			sendAudio: { try await live.sendAudio($0) },
			sendAudioFileTail: { try await live.sendAudioFileTail(
				$0,
				source: $1,
				takeGeneration: $2,
				startOffset: $3,
				committedThroughSample: $4
			) },
			finish: { await live.finish(takeGeneration: $0, endsSession: $1) },
			cancel: { await live.cancel() }
		)
	}
}

extension DependencyValues {
	var liveTranscription: LiveTranscriptionClient {
		get { self[LiveTranscriptionClient.self] }
		set { self[LiveTranscriptionClient.self] = newValue }
	}
}

#if canImport(FluidAudio)
/// Reconstructs the cumulative timed transcript from FluidAudio's current-window updates.
enum LiveTranscriptionWordHistory {
	static func merging(
		_ existing: [TimedTranscriptWord],
		with incoming: [TimedTranscriptWord]
	) -> [TimedTranscriptWord] {
		guard !incoming.isEmpty else { return existing }
		guard !existing.isEmpty else { return incoming }

		var firstOverlap: (oldIndex: Int, newIndex: Int)?
		overlapSearch: for (newIndex, newWord) in incoming.enumerated() {
			for oldIndex in existing.indices.reversed() {
				let oldWord = existing[oldIndex]
				if oldWord.endTime < newWord.startTime - TimedTranscriptWord.matchingTimingTolerance {
					break
				}
				if oldWord.approximatelyMatches(newWord) {
					firstOverlap = (oldIndex, newIndex)
					break overlapSearch
				}
			}
		}

		let preservedPrefix: ArraySlice<TimedTranscriptWord>
		if let firstOverlap {
			let alignedIncomingStart = max(existing.startIndex, firstOverlap.oldIndex - firstOverlap.newIndex)
			preservedPrefix = existing[..<alignedIncomingStart]
		} else if let incomingStart = incoming.first?.startTime,
			let existingEnd = existing.last?.endTime,
			incomingStart < existingEnd - TimedTranscriptWord.matchingTimingTolerance
		{
			preservedPrefix = existing.prefix {
				$0.endTime < incomingStart - TimedTranscriptWord.matchingTimingTolerance
			}
		} else {
			preservedPrefix = existing[...]
		}

		return Array(preservedPrefix) + incoming
	}
}

enum LiveTranscriptionASRTuning {
	static let configuration = SlidingWindowAsrConfig(
		chunkSeconds: 2,
		hypothesisChunkSeconds: 1,
		leftContextSeconds: 6,
		rightContextSeconds: 2,
		minContextForConfirmation: 6,
		confirmationThreshold: 0.80
	)
}

private actor LiveTranscriptionClientLive {
	private var configuration: LiveTranscriptionConfiguration?
	private var asrStreams: [TranscriptAudioSource: SlidingWindowAsrManager] = [:]
	private var diarizers: [TranscriptAudioSource: any Diarizer] = [:]
	private var profileIDsBySpeaker: [TranscriptAudioSource: [Int: UUID]] = [:]
	private var blockedSources: Set<TranscriptAudioSource> = []
	private var updateTasks: [TranscriptAudioSource: Task<Void, Never>] = [:]
	private var processedThrough: [TranscriptAudioSource: TimeInterval] = [:]
	private var speechObservedThrough: [TranscriptAudioSource: TimeInterval] = [:]
	private var lastChunkSequences: [TranscriptAudioSource: Int] = [:]
	private var sourceOffsets: [TranscriptAudioSource: TimeInterval] = [:]
	private var diarizerTimeOffsets: [TranscriptAudioSource: TimeInterval] = [:]
	private var hypothesisGenerations: [TranscriptAudioSource: Int] = [:]
	private var latestHypotheses: [TranscriptAudioSource: LiveTranscriptionHypothesis] = [:]
	private var wordHistories: [TranscriptAudioSource: [TimedTranscriptWord]] = [:]
	private var eventContinuation: AsyncStream<LiveTranscriptionEvent>.Continuation?
	private var sortformerModels: SortformerModels?
	private var lsEENDModel: LSEENDModel?
	private var asrModels: [String: AsrModels] = [:]
	private var diarizerSessionID: UUID?
	private var diarizerMode: SpeakerDiarizationMode?

	func prepare(modelName: String, speakerMode: SpeakerDiarizationMode?) async throws {
		if asrModels[modelName] == nil {
			asrModels[modelName] = try await ParakeetClient.shared.loadedModels(modelName: modelName)
		}
		if let speakerMode {
			try await prepareSpeakerMode(speakerMode)
		}
	}

	func prepareSpeakerMode(_ mode: SpeakerDiarizationMode) async throws {
		switch mode {
		case .highAccuracyFour:
			if sortformerModels == nil {
				sortformerModels = try await SortformerModels.loadFromHuggingFace(config: .balancedV2_1)
			}
		case .moreSpeakersTen:
			if lsEENDModel == nil {
				lsEENDModel = try await LSEENDModel.loadFromHuggingFace(
					variant: .dihard3,
					stepSize: .step100ms,
					computeUnits: .cpuOnly
				)
			}
		}
	}

	func start(_ configuration: LiveTranscriptionConfiguration) async throws -> AsyncStream<LiveTranscriptionEvent> {
		let canReuseDiarizers = !configuration.isRecovery
			&& diarizerSessionID == configuration.sessionID
			&& diarizerMode == configuration.speakerMode
			&& configuration.speakerIdentificationEnabled
		await resetTranscription(keepingDiarizers: canReuseDiarizers)
		self.configuration = configuration

		try await prepare(
			modelName: configuration.modelName,
			speakerMode: configuration.speakerIdentificationEnabled ? configuration.speakerMode : nil
		)
		guard let models = asrModels[configuration.modelName] else {
			throw NSError(
				domain: "LiveTranscription",
				code: -2,
				userInfo: [NSLocalizedDescriptionKey: "The live transcription model could not be loaded."]
			)
		}

		let (events, continuation) = AsyncStream<LiveTranscriptionEvent>.makeStream()
		eventContinuation = continuation

		for source in configuration.sources {
			let stream = SlidingWindowAsrManager(config: LiveTranscriptionASRTuning.configuration)
			try await stream.loadModels(models)
			try await stream.startStreaming(source: source.fluidAudioSource)
			asrStreams[source] = stream
			if configuration.speakerIdentificationEnabled, diarizers[source] == nil {
				try await installDiarizer(for: source, configuration: configuration)
			}
			if let diarizer = diarizers[source] {
				let frameRate = diarizer.modelFrameHz ?? 10
				diarizerTimeOffsets[source] = frameRate > 0
					? TimeInterval(diarizer.numFramesProcessed) / frameRate
					: 0
			}

			let updates = await stream.transcriptionUpdates
			updateTasks[source] = Task { [weak self] in
				for await update in updates {
					guard !Task.isCancelled else { return }
					await self?.receive(update, source: source, takeGeneration: configuration.takeGeneration)
				}
			}
		}
		if configuration.speakerIdentificationEnabled {
			diarizerSessionID = configuration.sessionID
			diarizerMode = configuration.speakerMode
		}

		liveTranscriptionLogger.notice(
			"Live transcription started sources=\(configuration.sources.count, privacy: .public) speakerMode=\(configuration.speakerMode.rawValue, privacy: .public)"
		)
		return events
	}

	func sendAudio(_ chunk: CapturedAudioChunk) async throws {
		guard let configuration, configuration.takeGeneration == chunk.takeGeneration,
			let stream = asrStreams[chunk.source]
		else { return }
		let sequenceIsDiscontinuous = lastChunkSequences[chunk.source].map {
			chunk.sequence != $0 + 1
		} ?? false
		lastChunkSequences[chunk.source] = chunk.sequence
		if chunk.discontinuityBefore || sequenceIsDiscontinuous {
			blockedSources.insert(chunk.source)
			eventContinuation?.yield(.sourceDiscontinuity(
				chunk.takeGeneration,
				chunk.source,
				chunk.startSample
			))
			return
		}
		guard !blockedSources.contains(chunk.source) else { return }

		guard let buffer = Self.buffer(from: chunk.samples, sampleRate: chunk.sampleRate) else { return }
		if sourceOffsets[chunk.source] == nil {
			sourceOffsets[chunk.source] = TimeInterval(chunk.startSample) / chunk.sampleRate
		}
		processedThrough[chunk.source] = TimeInterval(chunk.endSample) / chunk.sampleRate
		let meanSquare = chunk.samples.reduce(0.0) { partial, sample in
			partial + Double(sample * sample)
		} / Double(max(1, chunk.samples.count))
		if sqrt(meanSquare) >= 0.008 {
			speechObservedThrough[chunk.source] = max(
				speechObservedThrough[chunk.source] ?? 0,
				TimeInterval(chunk.endSample) / chunk.sampleRate
			)
		}
		await stream.streamAudio(buffer)
		if let diarizer = diarizers[chunk.source] {
			do {
				_ = try diarizer.process(samples: chunk.samples, sourceSampleRate: chunk.sampleRate)
			} catch {
				diarizer.cleanup()
				diarizers.removeValue(forKey: chunk.source)
				profileIDsBySpeaker.removeValue(forKey: chunk.source)
				eventContinuation?.yield(.speakerWarning(
					chunk.takeGeneration,
					chunk.source,
					error.localizedDescription
				))
			}
		}

		let observed = processedThrough[chunk.source] ?? 0
		let confirmed = await stream.confirmedTranscript
		let volatile = await stream.volatileTranscript
		let estimatedBacklog = confirmed.isEmpty && volatile.isEmpty ? min(20, observed) : 8
		eventContinuation?.yield(.backlog(estimatedBacklog))
	}

	func sendAudioFileTail(
		_ audioURL: URL,
		source: TranscriptAudioSource,
		takeGeneration: UUID,
		startOffset: TimeInterval,
		committedThroughSample: Int64
	) async throws {
		guard configuration?.takeGeneration == takeGeneration else { return }
		let converter = AudioConverter(sampleRate: 16_000)
		let samples = try converter.resampleAudioFile(audioURL)
		let offsetSamples = Int64((max(0, startOffset) * 16_000).rounded(.down))
		let localCommitted = max(0, committedThroughSample - offsetSamples)
		let localStart = max(0, localCommitted - 32_000)
		guard localStart < Int64(samples.count) else { return }

		var sequence = 0
		var index = Int(localStart)
		while index < samples.count {
			try Task.checkCancellation()
			let end = min(samples.count, index + 4_096)
			try await sendAudio(.init(
				source: source,
				takeGeneration: takeGeneration,
				sequence: sequence,
				startSample: offsetSamples + Int64(index),
				samples: Array(samples[index..<end])
			))
			sequence += 1
			index = end
		}
	}

	func finish(takeGeneration: UUID, endsSession: Bool) async {
		guard configuration?.takeGeneration == takeGeneration else { return }
		for stream in asrStreams.values {
			do {
				_ = try await stream.finish()
			} catch {
				eventContinuation?.yield(.failed(takeGeneration, error.localizedDescription))
			}
		}
		if endsSession {
			for diarizer in diarizers.values {
				do {
					_ = try diarizer.finalizeSession()
				} catch {
					liveTranscriptionLogger.warning(
						"Live diarizer tail failed error=\(error.localizedDescription, privacy: .private)"
					)
				}
			}
		}
		// `finish()` waits for recognition, but update-stream consumers may still be one
		// scheduler turn behind. Re-emit the final provider-confirmed hypothesis twice so
		// the append-only gate can apply its normal two-generation stability rule.
		try? await Task.sleep(for: .milliseconds(20))
		for source in asrStreams.keys {
			var final = latestHypotheses[source] ?? .init(
				source: source,
				takeGeneration: takeGeneration,
				generation: hypothesisGenerations[source] ?? 0,
				words: [],
				isProviderConfirmed: true,
				containsSpeech: false,
				requiresSpeakerAttribution: configuration?.speakerIdentificationEnabled == true,
				processedThrough: processedThrough[source] ?? 0,
				diarization: diarizationSnapshot(for: source)
			)
			final.isProviderConfirmed = true
			final.processedThrough = processedThrough[source] ?? final.processedThrough
			final.diarization = diarizationSnapshot(for: source)
			for _ in 0..<2 {
				let generation = (hypothesisGenerations[source] ?? final.generation) + 1
				hypothesisGenerations[source] = generation
				final.generation = generation
				latestHypotheses[source] = final
				eventContinuation?.yield(.hypothesis(final))
			}
		}
		eventContinuation?.yield(.drained(takeGeneration))
		eventContinuation?.finish()
	}

	func cancel() async {
		await resetTranscription(keepingDiarizers: false)
	}

	private func resetTranscription(keepingDiarizers: Bool) async {
		for task in updateTasks.values { task.cancel() }
		updateTasks.removeAll()
		for stream in asrStreams.values { await stream.cancel() }
		asrStreams.removeAll()
		if !keepingDiarizers {
			for diarizer in diarizers.values { diarizer.cleanup() }
			diarizers.removeAll()
			profileIDsBySpeaker.removeAll()
			diarizerSessionID = nil
			diarizerMode = nil
		}
		processedThrough.removeAll()
		speechObservedThrough.removeAll()
		lastChunkSequences.removeAll()
		blockedSources.removeAll()
		sourceOffsets.removeAll()
		diarizerTimeOffsets.removeAll()
		hypothesisGenerations.removeAll()
		latestHypotheses.removeAll()
		wordHistories.removeAll()
		eventContinuation?.finish()
		eventContinuation = nil
		configuration = nil
	}

	private func receive(
		_ update: SlidingWindowTranscriptionUpdate,
		source: TranscriptAudioSource,
		takeGeneration: UUID
	) {
		guard configuration?.takeGeneration == takeGeneration else { return }
		let offset = sourceOffsets[source] ?? 0
		let wordTimings = buildWordTimings(from: update.tokenTimings)
		let windowWords = wordTimings.map {
			TimedTranscriptWord(
				word: $0.word,
				startTime: $0.startTime + offset,
				endTime: $0.endTime + offset
			)
		}
		let words = LiveTranscriptionWordHistory.merging(
			wordHistories[source] ?? [],
			with: windowWords
		)
		wordHistories[source] = words
		let diarization = diarizationSnapshot(for: source)
		let modelSpeechThrough = max(
			words.map(\.endTime).max() ?? 0,
			diarization?.segments.map(\.endTime).max() ?? 0
		)
		let observedSpeechThrough = max(
			speechObservedThrough[source] ?? 0,
			modelSpeechThrough
		)
		speechObservedThrough[source] = observedSpeechThrough
		let containsSpeech = observedSpeechThrough > 0
		let generation = (hypothesisGenerations[source] ?? 0) + 1
		hypothesisGenerations[source] = generation
		let hypothesis = LiveTranscriptionHypothesis(
			source: source,
			takeGeneration: takeGeneration,
			generation: generation,
			words: words,
			isProviderConfirmed: update.isConfirmed,
			containsSpeech: containsSpeech,
			requiresSpeakerAttribution: configuration?.speakerIdentificationEnabled == true,
			processedThrough: processedThrough[source] ?? 0,
			diarization: diarization,
			speechObservedThrough: observedSpeechThrough
		)
		latestHypotheses[source] = hypothesis
		eventContinuation?.yield(.hypothesis(hypothesis))
	}

	private func installDiarizer(
		for source: TranscriptAudioSource,
		configuration: LiveTranscriptionConfiguration
	) async throws {
		switch configuration.speakerMode {
		case .highAccuracyFour:
			guard let sortformerModels else { return }
			let diarizer = SortformerDiarizer(config: .balancedV2_1)
			diarizer.initialize(models: sortformerModels)
			var profileIDs = [Int: UUID]()
			let converter = AudioConverter(sampleRate: 16_000)
			for profile in configuration.profiles.prefix(3) {
				guard let sample = (profile.audioSamples ?? []).first(where: {
					$0.duration >= SpeakerVoiceSampleStore.minimumEnrollmentDuration
						&& FileManager.default.fileExists(atPath: $0.audioURL.path)
				}) else { continue }
				do {
					let samples = try converter.resampleAudioFile(sample.audioURL)
					if let enrolled = try diarizer.enrollSpeaker(
						withAudio: samples,
						named: profile.id.uuidString,
						overwritingAssignedSpeakerName: false
					) {
						profileIDs[enrolled.index] = profile.id
					}
				} catch {
					liveTranscriptionLogger.warning(
						"Live speaker enrollment failed profile=\(profile.id.uuidString, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
					)
				}
			}
			diarizers[source] = diarizer
			profileIDsBySpeaker[source] = profileIDs
		case .moreSpeakersTen:
			guard let lsEENDModel else { return }
			let diarizer = try LSEENDDiarizer(model: lsEENDModel)
			var profileIDs = [Int: UUID]()
			let converter = AudioConverter(sampleRate: 16_000)
			for profile in configuration.profiles.prefix(configuration.speakerMode.speakerCapacity - 1) {
				let samples = (profile.audioSamples ?? []).filter {
					$0.duration >= SpeakerVoiceSampleStore.minimumEnrollmentDuration
						&& FileManager.default.fileExists(atPath: $0.audioURL.path)
				}
				// LS-EEND naming is deliberately stricter: a single enrollment clip is
				// insufficient evidence to attach a durable saved-profile identity.
				guard samples.count >= 2 else { continue }
				do {
					var enrollmentAudio = [Float]()
					for sample in samples.prefix(2) {
						enrollmentAudio.append(contentsOf: try converter.resampleAudioFile(sample.audioURL))
						enrollmentAudio.append(contentsOf: repeatElement(Float.zero, count: 8_000))
					}
					if let enrolled = try diarizer.enrollSpeaker(
						withAudio: enrollmentAudio,
						sourceSampleRate: 16_000,
						named: profile.id.uuidString,
						overwritingAssignedSpeakerName: false
					) {
						profileIDs[enrolled.index] = profile.id
					}
				} catch {
					liveTranscriptionLogger.warning(
						"LS-EEND speaker enrollment failed profile=\(profile.id.uuidString, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
					)
				}
			}
			diarizers[source] = diarizer
			profileIDsBySpeaker[source] = profileIDs
		}
	}

	private func diarizationSnapshot(for source: TranscriptAudioSource) -> SpeakerDiarizationOutput? {
		guard let diarizer = diarizers[source] else { return nil }
		let profileIDs = profileIDsBySpeaker[source] ?? [:]
		let offset = sourceOffsets[source] ?? 0
		let diarizerOffset = diarizerTimeOffsets[source] ?? 0
		var segments: [SpeakerDiarizationSegment] = []
		for speaker in diarizer.timeline.speakers.values {
			for segment in speaker.finalizedSegments + speaker.tentativeSegments {
				guard TimeInterval(segment.endTime) > diarizerOffset else { continue }
				segments.append(
					SpeakerDiarizationSegment(
						speakerID: "\(configuration?.speakerMode.rawValue ?? "speaker")-\(segment.speakerIndex)",
						embedding: [],
						startTime: max(0, TimeInterval(segment.startTime) - diarizerOffset) + offset,
						endTime: max(0, TimeInterval(segment.endTime) - diarizerOffset) + offset,
						qualityScore: segment.activity.isFinite ? segment.activity : 0,
						profileID: profileIDs[segment.speakerIndex]
					)
				)
			}
		}
		segments.sort { lhs, rhs in
			if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
			return lhs.speakerID < rhs.speakerID
		}
		return .init(segments: segments)
	}

	private static func buffer(from samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
		guard !samples.isEmpty,
			let format = AVAudioFormat(
				commonFormat: .pcmFormatFloat32,
				sampleRate: sampleRate,
				channels: 1,
				interleaved: false
			),
			let buffer = AVAudioPCMBuffer(
				pcmFormat: format,
				frameCapacity: AVAudioFrameCount(samples.count)
			),
			let destination = buffer.floatChannelData?[0]
		else { return nil }
		buffer.frameLength = AVAudioFrameCount(samples.count)
		samples.withUnsafeBufferPointer { source in
			if let base = source.baseAddress {
				destination.update(from: base, count: samples.count)
			}
		}
		return buffer
	}
}

private extension TranscriptAudioSource {
	var fluidAudioSource: AudioSource {
		switch self {
		case .microphone: .microphone
		case .systemAudio: .system
		}
	}
}
#else
private actor LiveTranscriptionClientLive {
	func prepare(modelName _: String, speakerMode _: SpeakerDiarizationMode?) async throws {
		throw NSError(domain: "LiveTranscription", code: -1, userInfo: [NSLocalizedDescriptionKey: "FluidAudio is unavailable."])
	}

	func prepareSpeakerMode(_: SpeakerDiarizationMode) async throws {
		throw NSError(domain: "LiveTranscription", code: -1, userInfo: [NSLocalizedDescriptionKey: "FluidAudio is unavailable."])
	}

	func start(_: LiveTranscriptionConfiguration) async throws -> AsyncStream<LiveTranscriptionEvent> {
		throw NSError(domain: "LiveTranscription", code: -1, userInfo: [NSLocalizedDescriptionKey: "FluidAudio is unavailable."])
	}

	func sendAudio(_: CapturedAudioChunk) async throws {}
	func sendAudioFileTail(
		_: URL,
		source _: TranscriptAudioSource,
		takeGeneration _: UUID,
		startOffset _: TimeInterval,
		committedThroughSample _: Int64
	) async throws {}
	func finish(takeGeneration _: UUID, endsSession _: Bool) async {}
	func cancel() async {}
}
#endif
