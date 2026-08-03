import AVFoundation
import AppKit
import ComposableArchitecture
import Dependencies
import HexCore
import ImageIO
import Inject
import SwiftUI
import WhisperKit

private let historyLogger = HexLog.history

private enum AudioPlayerError: Error {
	case failedToStart
}

private final class ScreenshotImageCache: @unchecked Sendable {
	private static let maximumPixelDimension = 1_600
	private static let maximumImageCount = 24
	private static let maximumDecodedByteCost = 64 * 1_024 * 1_024

	private let storage = NSCache<NSURL, NSImage>()

	init() {
		storage.countLimit = Self.maximumImageCount
		storage.totalCostLimit = Self.maximumDecodedByteCost
	}

	func image(at url: URL) -> NSImage? {
		let cacheKey = url as NSURL
		if let cached = storage.object(forKey: cacheKey) { return cached }

		guard let source = CGImageSourceCreateWithURL(
			url as CFURL,
			[kCGImageSourceShouldCache: false] as CFDictionary
		) else { return nil }

		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixelDimension,
			kCGImageSourceShouldCacheImmediately: true,
		]
		guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
			source,
			0,
			options as CFDictionary
		) else { return nil }

		let image = NSImage(
			cgImage: thumbnail,
			size: NSSize(width: thumbnail.width, height: thumbnail.height)
		)
		storage.setObject(
			image,
			forKey: cacheKey,
			cost: thumbnail.bytesPerRow * thumbnail.height
		)
		return image
	}
}

private let screenshotImageCache = ScreenshotImageCache()

/// Performs the history search entirely in memory. Only the spoken transcript and
/// generated output participate, so metadata and captured screen context stay out of
/// search results.
enum HistorySearch {
	static func matchingIDs(in history: [Transcript], query: String) -> Set<UUID> {
		let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
		guard !terms.isEmpty else { return Set(history.map(\.id)) }
		let legacyRawTranscripts = history.reduce(into: [URL: String]()) { result, transcript in
			guard transcript.isRefinementSource == true else { return }
			result[transcript.audioPath] = transcript.text
		}

		return Set(history.compactMap { transcript in
			guard transcript.isRefinementSource != true else { return nil }
			let legacyRawTranscript = legacyRawTranscripts[transcript.audioPath]
			let rawTranscript = transcript.rawText ?? legacyRawTranscript ?? transcript.text
			let searchableText = [rawTranscript, transcript.text]
				.joined(separator: "\n")
			return terms.contains { searchableText.range(of: $0, options: .caseInsensitive) != nil }
				? transcript.id
				: nil
		})
	}
}

private func highlightedText(_ text: String, matching query: String) -> AttributedString {
	var attributedText = AttributedString(text)
	for term in query.split(whereSeparator: \.isWhitespace) where !term.isEmpty {
		var searchRange = attributedText.startIndex..<attributedText.endIndex
		while let range = attributedText[searchRange].range(of: term, options: .caseInsensitive) {
			attributedText[range].backgroundColor = .yellow.opacity(0.35)
			searchRange = range.upperBound..<attributedText.endIndex
		}
	}
	return attributedText
}

// MARK: - Date Extensions

extension Date {
	func relativeFormatted() -> String {
		let calendar = Calendar.current
		let now = Date()
		
		if calendar.isDateInToday(self) {
			return "Today"
		} else if calendar.isDateInYesterday(self) {
			return "Yesterday"
		} else if let daysAgo = calendar.dateComponents([.day], from: self, to: now).day, daysAgo < 7 {
			let formatter = DateFormatter()
			formatter.dateFormat = "EEEE" // Day of week
			return formatter.string(from: self)
		} else {
			let formatter = DateFormatter()
			formatter.dateStyle = .medium
			formatter.timeStyle = .none
			return formatter.string(from: self)
		}
	}
}

// MARK: - Models

extension SharedReaderKey
	where Self == FileStorageKey<TranscriptionHistory>.Default
{
	static var transcriptionHistory: Self {
		Self[
			.fileStorage(.transcriptionHistoryURL),
			default: .init()
		]
	}
}

// MARK: - Storage

extension URL {
	static var transcriptionHistoryURL: URL {
		get {
			URL.hexStoredFileURL(named: "transcription_history.json")
		}
	}
}

class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
	private var player: AVAudioPlayer?
	private let (playbackFinishedStream, playbackFinishedContinuation) = AsyncStream<Void>.makeStream()

	func play(url: URL, startingAt time: TimeInterval = 0) throws -> TimeInterval {
		let player = try AVAudioPlayer(contentsOf: url)
		player.delegate = self
		player.currentTime = min(max(0, time), player.duration)
		self.player = player
		guard player.play() else { throw AudioPlayerError.failedToStart }
		return player.duration
	}

	func seekAndPlay(to time: TimeInterval) -> Bool {
		guard let player else { return false }
		player.currentTime = min(max(0, time), player.duration)
		return player.isPlaying || player.play()
	}

	func pause() {
		player?.pause()
	}

	func resume() -> Bool {
		player?.play() ?? false
	}

	var currentTime: TimeInterval { player?.currentTime ?? 0 }

	func stop() {
		player?.stop()
		player = nil
		finishPlayback()
	}

	func waitForPlaybackToFinish() async {
		for await _ in playbackFinishedStream {}
	}

	// AVAudioPlayerDelegate method
	func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
		guard self.player === player else { return }
		self.player = nil
		finishPlayback()
	}

	private func finishPlayback() {
		playbackFinishedContinuation.finish()
	}
}

// MARK: - History Feature

@Reducer
struct HistoryFeature {
	struct ReplayResult: Equatable, Sendable {
		let rawText: String
		let outputText: String
		let timestampedSections: [TimestampedTranscriptSection]?
		let wasRefined: Bool
		let outputGenerationDuration: TimeInterval?
	}

	@ObservableState
	struct State: Equatable {
		@Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
		var playingTranscriptID: UUID?
		var playbackID: UUID?
		var audioPlayerController: AudioPlayerController?
		var playbackProgress: TimeInterval = 0
		var playbackDuration: TimeInterval = 0
		var isPlaybackPaused = false
		var rerunningTranscriptIDs: Set<UUID> = []

		mutating func stopAudioPlayback() {
			audioPlayerController?.stop()
			audioPlayerController = nil
			playingTranscriptID = nil
			playbackID = nil
			playbackProgress = 0
			playbackDuration = 0
			isPlaybackPaused = false
		}
	}

	enum Action {
		case playTranscript(UUID)
		case stopPlayback
		case copyToClipboard(String)
		case deleteTranscript(UUID)
		case deleteAllTranscripts
		case confirmDeleteAll
		case playbackFinished(UUID)
		case playbackProgressed(UUID, TimeInterval)
		case seekTranscript(UUID, TimeInterval)
		case rerunTranscription(UUID)
		case rerunFullRun(UUID)
		case replaySucceeded(UUID, ReplayResult)
		case replayFailed(UUID, TranscriptProcessingStage, String)
		case navigateToSettings
	}

	@Dependency(\.pasteboard) var pasteboard
	@Dependency(\.transcriptPersistence) var transcriptPersistence
	@Dependency(\.transcription) var transcription
	@Dependency(\.refinement) var refinement
	@Dependency(\.date.now) var now

	private enum CancelID: Hashable {
		case playbackProgress
		case replay(UUID)
	}

	private func deleteTranscriptFilesEffect(for transcripts: [Transcript]) -> Effect<Action> {
		.run { [transcriptPersistence] _ in
			var deletedAudioPaths = Set<URL>()
			for transcript in transcripts where deletedAudioPaths.insert(transcript.audioPath).inserted {
				try? await transcriptPersistence.deleteArtifacts(transcript)
			}
		}
	}

	private func replay(
		_ state: inout State,
		id: UUID,
		includeProcessing: Bool
	) -> Effect<Action> {
		guard !state.rerunningTranscriptIDs.contains(id),
			  let transcript = state.transcriptionHistory.history.first(where: { $0.id == id })
		else { return .none }

		state.rerunningTranscriptIDs.insert(id)
		return .run { [transcription, refinement] send in
			@Shared(.hexSettings) var settings: HexSettings
			let decodingOptions = DecodingOptions(
				language: settings.outputLanguage,
				detectLanguage: settings.outputLanguage == nil,
				chunkingStrategy: .vad
			)

			let transcriptionOutput: TranscriptionOutput
			do {
				transcriptionOutput = try await transcription.transcribe(
					transcript.audioPath,
					settings.selectedModel,
					decodingOptions
				) { _ in }
			} catch {
				await send(.replayFailed(id, .transcription, error.localizedDescription))
				return
			}
			let rawText = transcriptionOutput.canonicalText
			let timestampedSections = transcriptionOutput.timestampedSections.isEmpty
				? nil
				: transcriptionOutput.timestampedSections

			let shouldReprocess = includeProcessing && (
				transcript.wasRefined == true
				|| transcript.selectedText != nil
				|| transcript.screenshotPath != nil
			)
			guard shouldReprocess else {
				await send(.replaySucceeded(id, .init(
					rawText: rawText,
					outputText: rawText,
					timestampedSections: timestampedSections,
					wasRefined: false,
					outputGenerationDuration: nil
				)))
				return
			}

			do {
				let outputGenerationStartedAt = now
				let request: RefinementRequest
				if let screenshotPath = transcript.screenshotPath {
					let imageData = try Data(contentsOf: screenshotPath)
					let context = ScreenContext(
						imagePNGData: imageData,
						recognizedText: transcript.screenshotRecognizedText ?? "",
						pixelWidth: 0,
						pixelHeight: 0,
						cursorX: 0,
						cursorY: 0
					)
					let inputSource = transcript.screenAwareInputSource ?? .image
					let imageModelID = inputSource.uploadsScreenshot
						? OpenRouterModelCatalog.selectedImageCapableModelID(for: settings)
						: nil
					request = settings.screenAwareRequest(
						for: rawText,
						context: context,
						inputSource: inputSource,
						imageModelID: imageModelID
					)
				} else {
					let selectedText = transcript.selectedText
					request = settings.refinementRequest(
						for: selectedText ?? rawText,
						mode: .refined,
						spokenInstruction: selectedText == nil ? nil : rawText
					)
				}
				let outputText = try await refinement.refine(request)
				await send(.replaySucceeded(id, .init(
					rawText: rawText,
					outputText: outputText,
					timestampedSections: timestampedSections,
					wasRefined: true,
					outputGenerationDuration: now.timeIntervalSince(outputGenerationStartedAt)
				)))
			} catch {
				await send(.replayFailed(id, .processing, error.localizedDescription))
			}
		}
		.cancellable(id: CancelID.replay(id), cancelInFlight: true)
	}

	private func startPlayback(
		_ state: inout State,
		id: UUID,
		startingAt time: TimeInterval
	) -> Effect<Action> {
		guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
			return .cancel(id: CancelID.playbackProgress)
		}

		do {
			let controller = AudioPlayerController()
			let duration = try controller.play(url: transcript.audioPath, startingAt: time)
			let playbackID = UUID()

			state.audioPlayerController = controller
			state.playingTranscriptID = id
			state.playbackID = playbackID
			state.playbackDuration = duration
			state.playbackProgress = controller.currentTime
			state.isPlaybackPaused = false

			let waitForPlayback = Effect<Action>.run { send in
				await controller.waitForPlaybackToFinish()
				await send(.playbackFinished(playbackID))
			}
			return .merge(waitForPlayback, playbackProgressEffect(controller: controller, playbackID: playbackID))
		} catch {
			historyLogger.error("Failed to play audio: \(error.localizedDescription)")
			return .cancel(id: CancelID.playbackProgress)
		}
	}

	private func playbackProgressEffect(
		controller: AudioPlayerController,
		playbackID: UUID
	) -> Effect<Action> {
		.run { send in
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(50))
				guard !Task.isCancelled else { return }
				await send(.playbackProgressed(playbackID, controller.currentTime))
			}
		}
		.cancellable(id: CancelID.playbackProgress, cancelInFlight: true)
	}

	var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case let .playTranscript(id):
				if state.playingTranscriptID == id {
					guard let controller = state.audioPlayerController,
						  let playbackID = state.playbackID
					else { return .none }
					if state.isPlaybackPaused {
						guard controller.resume() else {
							state.stopAudioPlayback()
							return .cancel(id: CancelID.playbackProgress)
						}
						state.isPlaybackPaused = false
						return playbackProgressEffect(controller: controller, playbackID: playbackID)
					} else {
						controller.pause()
						state.isPlaybackPaused = true
						return .cancel(id: CancelID.playbackProgress)
					}
				}

				// Stop any existing playback
				state.stopAudioPlayback()
				return startPlayback(&state, id: id, startingAt: 0)

			case .stopPlayback:
				state.stopAudioPlayback()
				return .cancel(id: CancelID.playbackProgress)

			case let .playbackFinished(playbackID):
				guard state.playbackID == playbackID else { return .none }
				state.stopAudioPlayback()
				return .cancel(id: CancelID.playbackProgress)

			case let .playbackProgressed(playbackID, time):
				guard state.playbackID == playbackID else { return .none }
				let clampedTime = min(max(0, time), state.playbackDuration)
				guard state.playbackProgress != clampedTime else { return .none }
				state.playbackProgress = clampedTime
				return .none

			case let .seekTranscript(id, time):
				if state.playingTranscriptID == id {
					guard let controller = state.audioPlayerController,
						  let playbackID = state.playbackID
					else { return .none }
					guard controller.seekAndPlay(to: time) else {
						state.stopAudioPlayback()
						return .cancel(id: CancelID.playbackProgress)
					}
					state.playbackProgress = min(max(0, time), state.playbackDuration)
					state.isPlaybackPaused = false
					return playbackProgressEffect(controller: controller, playbackID: playbackID)
				}

				state.stopAudioPlayback()
				return startPlayback(&state, id: id, startingAt: time)

			case let .rerunTranscription(id):
				return replay(&state, id: id, includeProcessing: false)

			case let .rerunFullRun(id):
				return replay(&state, id: id, includeProcessing: true)

			case let .replaySucceeded(id, result):
				state.rerunningTranscriptIDs.remove(id)
				state.$transcriptionHistory.withLock { history in
					guard let index = history.history.firstIndex(where: { $0.id == id }) else { return }
					history.history[index].rawText = result.rawText
					history.history[index].text = result.outputText
					history.history[index].timestampedSections = result.timestampedSections
					history.history[index].wasRefined = result.wasRefined
					history.history[index].outputGenerationDuration = result.outputGenerationDuration
					// Replay does not run speaker identification, so retained labels would no
					// longer describe the newly generated transcript.
					history.history[index].speakerSegments = nil
					history.history[index].status = .completed
					history.history[index].processingErrors = nil
				}
				return .none

			case let .replayFailed(id, stage, message):
				state.rerunningTranscriptIDs.remove(id)
				state.$transcriptionHistory.withLock { history in
					guard let index = history.history.firstIndex(where: { $0.id == id }) else { return }
					history.history[index].status = .failed
					history.history[index].processingErrors = [
						.init(stage: stage, message: message)
					]
				}
				return .none

			case let .copyToClipboard(text):
				return .run { [pasteboard] _ in
					await pasteboard.copy(text)
				}

			case let .deleteTranscript(id):
				guard let transcript = state.transcriptionHistory.history.first(where: { $0.id == id }) else {
					return .none
				}

				if state.playingTranscriptID == id {
					state.stopAudioPlayback()
				}

				_ = state.$transcriptionHistory.withLock { history in
					history.history.removeAll { $0.audioPath == transcript.audioPath }
				}
				let recordingIsStillReferenced = state.transcriptionHistory.history.contains { $0.audioPath == transcript.audioPath }

				guard !recordingIsStillReferenced else { return .none }
				return .merge(
					.cancel(id: CancelID.playbackProgress),
					deleteTranscriptFilesEffect(for: [transcript])
				)

			case .deleteAllTranscripts:
				return .send(.confirmDeleteAll)

			case .confirmDeleteAll:
				let transcripts = state.transcriptionHistory.history
				state.stopAudioPlayback()

				state.$transcriptionHistory.withLock { history in
					history.history.removeAll()
				}

				return .merge(
					.cancel(id: CancelID.playbackProgress),
					deleteTranscriptFilesEffect(for: transcripts)
				)
				
			case .navigateToSettings:
				// This will be handled by the parent reducer
				return .none
			}
		}
	}
}

private struct AudioWaveformSamples {
	static func load(from url: URL, count: Int = 72) -> [CGFloat] {
		do {
			let file = try AVAudioFile(forReading: url)
			let frameCount = AVAudioFrameCount(min(file.length, 1_500_000))
			guard frameCount > 0,
				  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
			else { return [] }
			try file.read(into: buffer, frameCount: frameCount)
			guard let samples = buffer.floatChannelData else { return [] }

			let framesPerBucket = max(1, Int(buffer.frameLength) / count)
			return (0..<count).map { bucket in
				let start = bucket * framesPerBucket
				let end = min(Int(buffer.frameLength), start + framesPerBucket)
				guard start < end else { return 0.08 }
				let peak = (start..<end).reduce(Float.zero) { maximum, frame in
					max(maximum, abs(samples[0][frame]))
				}
				return max(0.08, min(1, CGFloat(peak.squareRoot())))
			}
		} catch {
			return []
		}
	}
}

private struct AudioWaveformView: View {
	let audioURL: URL
	let progress: TimeInterval
	let duration: TimeInterval
	let startOffset: TimeInterval
	let trackDuration: TimeInterval
	let onSeek: (TimeInterval) -> Void
	let showsSeekControl: Bool
	@State private var samples: [CGFloat] = []

	init(
		audioURL: URL,
		progress: TimeInterval,
		duration: TimeInterval,
		startOffset: TimeInterval = 0,
		trackDuration: TimeInterval? = nil,
		showsSeekControl: Bool = true,
		onSeek: @escaping (TimeInterval) -> Void
	) {
		self.audioURL = audioURL
		self.progress = progress
		self.duration = duration
		self.startOffset = startOffset
		self.trackDuration = trackDuration ?? duration
		self.showsSeekControl = showsSeekControl
		self.onSeek = onSeek
	}

	var body: some View {
		VStack(spacing: 4) {
			Canvas { context, size in
				let bars = samples.isEmpty ? Array(repeating: CGFloat(0.22), count: 48) : samples
				let channelDuration = min(max(0.01, trackDuration), max(0.01, duration - startOffset))
				let channelStart = min(1, max(0, startOffset / max(0.01, duration)))
				let channelWidth = min(1 - channelStart, channelDuration / max(0.01, duration))
				let availableWidth = max(0.01, size.width * channelWidth)
				let spacing = min(CGFloat(2), availableWidth / CGFloat(max(1, bars.count - 1)) / 2)
				let barWidth = max(0.01, (availableWidth - spacing * CGFloat(bars.count - 1)) / CGFloat(bars.count))
				for (index, sample) in bars.enumerated() {
					let height = max(3, size.height * sample)
					let x = size.width * channelStart + CGFloat(index) * (barWidth + spacing)
					let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
					let sampleTime = startOffset + channelDuration * Double(index) / Double(max(1, bars.count - 1))
					let color: Color = sampleTime <= progress ? .accentColor : .secondary.opacity(0.28)
					context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
				}
			}
			.frame(height: 34)

			if showsSeekControl {
				AudioSeekBar(value: progress, duration: duration, onSeek: onSeek)
			}
		}
		.task(id: audioURL) {
			samples = await Task.detached(priority: .utility) {
				AudioWaveformSamples.load(from: audioURL)
			}.value
		}
	}
}

/// A SwiftUI-only playback scrubber. The native macOS `Slider` can recursively
/// re-enter AppKit sizing when many history rows are mounted, freezing the app.
private struct AudioSeekBar: View {
	let value: TimeInterval
	let duration: TimeInterval
	let onSeek: (TimeInterval) -> Void

	private var safeDuration: TimeInterval {
		duration.isFinite ? max(0.01, duration) : 0.01
	}

	private var safeValue: TimeInterval {
		guard value.isFinite else { return 0 }
		return min(max(0, value), safeDuration)
	}

	private var fraction: CGFloat {
		CGFloat(safeValue / safeDuration)
	}

	var body: some View {
		GeometryReader { geometry in
			let thumbDiameter: CGFloat = 12
			let trackWidth = max(1, geometry.size.width - thumbDiameter)

			ZStack(alignment: .leading) {
				Capsule()
					.fill(.secondary.opacity(0.28))
					.frame(height: 4)
					.padding(.horizontal, thumbDiameter / 2)

				Capsule()
					.fill(Color.accentColor)
					.frame(width: max(0.5, trackWidth * fraction), height: 4)
					.offset(x: thumbDiameter / 2)

				Circle()
					.fill(Color.accentColor)
					.frame(width: thumbDiameter, height: thumbDiameter)
					.offset(x: trackWidth * fraction)
			}
			.frame(maxHeight: .infinity)
			.contentShape(Rectangle())
			.gesture(
				DragGesture(minimumDistance: 0)
					.onChanged { gesture in
						let proposedFraction = (gesture.location.x - thumbDiameter / 2) / trackWidth
						let clampedFraction = min(max(0, proposedFraction), 1)
						onSeek(safeDuration * TimeInterval(clampedFraction))
					}
			)
		}
		.frame(height: 16)
		.accessibilityElement()
		.accessibilityLabel("Playback position")
		.accessibilityValue("\(Int((safeValue / safeDuration) * 100)) percent")
		.accessibilityAdjustableAction { direction in
			let step = max(1, safeDuration / 20)
			switch direction {
			case .increment:
				onSeek(min(safeDuration, safeValue + step))
			case .decrement:
				onSeek(max(0, safeValue - step))
			@unknown default:
				break
			}
		}
	}
}

private struct RunHistoryItemView: View {
	private enum TranscriptPresentation: Hashable {
		case textOnly
		case timestampsAndSpeakerLabels
	}

	let transcript: Transcript
	let legacyRawTranscript: String?
	let isPlaying: Bool
	let isPlaybackPaused: Bool
	let playbackProgress: TimeInterval
	let playbackDuration: TimeInterval
	let isRerunning: Bool
	let onPlay: () -> Void
	let onSeek: (TimeInterval) -> Void
	let onCopy: () -> Void
	let onRerunTranscription: () -> Void
	let onRerunFullRun: () -> Void
	let onDelete: () -> Void
	let onOpenSpeaker: (UUID) -> Void
	let searchQuery: String
	@Shared(.speakerVoiceLibrary) private var speakerVoiceLibrary: SpeakerVoiceLibrary
	@State private var transcriptPresentation: TranscriptPresentation = .textOnly
	@State private var isHoveringTranscription = false
	@FocusState private var focusedTranscriptPresentation: TranscriptPresentation?

	private var rawTranscript: String { transcript.rawText ?? legacyRawTranscript ?? transcript.text }
	private var hasDistinctResult: Bool { transcript.text != rawTranscript || transcript.wasRefined == true }
	private var timestampedSections: [TimestampedTranscriptSection] { transcript.timestampedSections ?? [] }
	private var speakerSegments: [SpeakerAttributedSegment] { transcript.speakerSegments ?? [] }
	private func speakerSegment(for section: TimestampedTranscriptSection) -> SpeakerAttributedSegment? {
		let matchingSegments = speakerSegments.filter {
			$0.startTime <= section.startTime && $0.endTime >= section.endTime
		}
		return matchingSegments.count == 1 ? matchingSegments[0] : nil
	}
	private func speakerProfile(for section: TimestampedTranscriptSection) -> SpeakerVoiceProfile? {
		guard let profileID = speakerSegment(for: section)?.profileID else { return nil }
		return speakerVoiceLibrary.profiles.first { $0.id == profileID }
	}
	private func speakerName(for section: TimestampedTranscriptSection) -> String? {
		if let profile = speakerProfile(for: section) { return profile.name }
		if let displayLabel = section.displayLabel { return displayLabel }
		return speakerSegment(for: section)?.speakerName
	}
	private var shouldShowTranscriptPresentationControls: Bool {
		isHoveringTranscription || focusedTranscriptPresentation != nil
	}
	private var screenshotByteCount: Int? {
		if let screenshotByteCount = transcript.screenshotByteCount { return screenshotByteCount }
		return try? transcript.screenshotPath?.resourceValues(forKeys: [.fileSizeKey]).fileSize
	}
	private var audioChannels: [TranscriptAudioChannel] {
		let channels = transcript.audioChannels ?? []
		guard channels.count > 1 else { return [] }
		return channels.sorted { $0.source == .microphone && $1.source != .microphone }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			section("Audio", systemImage: "waveform") {
				let audioProgress = isPlaying || isPlaybackPaused ? playbackProgress : 0
				let audioDuration = isPlaying || isPlaybackPaused ? playbackDuration : transcript.duration
				if audioChannels.isEmpty {
					AudioWaveformView(audioURL: transcript.audioPath, progress: audioProgress, duration: audioDuration, onSeek: onSeek)
				} else {
					VStack(alignment: .leading, spacing: 7) {
						ForEach(audioChannels) { channel in
							VStack(alignment: .leading, spacing: 3) {
								Label(channel.source.displayName, systemImage: channel.source == .microphone ? "mic.fill" : "speaker.wave.2.fill")
									.font(.caption.weight(.medium))
									.foregroundStyle(.secondary)
								AudioWaveformView(
									audioURL: channel.audioPath,
									progress: audioProgress,
									duration: audioDuration,
									startOffset: channel.startOffset,
									trackDuration: channel.duration,
									showsSeekControl: false,
									onSeek: onSeek
								)
							}
						}
						AudioSeekBar(value: audioProgress, duration: audioDuration, onSeek: onSeek)
					}
				}
				HStack(spacing: 8) {
					Button(action: onPlay) {
						Image(systemName: isPlaying ? "pause.fill" : "play.fill")
					}
					.buttonStyle(.plain)
					.foregroundStyle(isPlaying || isPlaybackPaused ? Color.accentColor : .secondary)
					.help(isPlaying ? "Pause audio" : "Play audio")
					.accessibilityLabel(isPlaying ? "Pause audio" : "Play audio")
					Text(format(audioProgress))
					Spacer()
					Text(format(audioDuration))
				}
				.font(.caption.monospacedDigit())
				.foregroundStyle(.secondary)
			}

			transcriptionSection

			if let selectedText = transcript.selectedText, !selectedText.isEmpty {
				section("Selected text", systemImage: "selection.pin.in.out") {
					Text(selectedText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
				}
			}

			if let screenshotPath = transcript.screenshotPath {
				section("Screen context", systemImage: "display") {
					if let source = transcript.screenAwareInputSource {
						Label(source.historyLabel, systemImage: source.historySystemImage)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					if let screenshotByteCount {
						Label("\(formatMegabytes(screenshotByteCount))", systemImage: "internaldrive")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					if let screenshot = screenshotImageCache.image(at: screenshotPath) {
						Image(nsImage: screenshot).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 6))
					} else {
						Label("The saved screenshot is no longer available.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
					}
					if let recognizedText = transcript.screenshotRecognizedText, !recognizedText.isEmpty {
						Text("Recognized text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
						Text(recognizedText).font(.caption).textSelection(.enabled)
					}
				}
			}

			if let errors = transcript.processingErrors, !errors.isEmpty {
				section("Processing errors", systemImage: "exclamationmark.triangle.fill") {
					ForEach(errors) { error in
						VStack(alignment: .leading, spacing: 2) {
							Text(error.stage.displayName).font(.caption.weight(.semibold))
							Text(error.message).font(.caption).textSelection(.enabled)
						}.padding(8).background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
					}
				}
			}

			Divider()
			footer
		}
		.background(
			Color.octoCardBackground,
			in: RoundedRectangle(cornerRadius: 8, style: .continuous)
		)
	}

	private var transcriptionSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Label("Transcription", systemImage: "text.quote")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
				Spacer(minLength: 8)
				transcriptPresentationControls
			}

			if let status = transcript.status, status != .completed {
				Label(status.historyLabel, systemImage: status.historySystemImage)
					.font(.caption.weight(.semibold))
					.foregroundStyle(status == .failed ? .red : .secondary)
			}

			transcriptPresentationContent

			if hasDistinctResult {
				Divider().padding(.vertical, 4)
				Text("Result").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
				Text(highlightedText(
					transcript.text.isEmpty ? "No result was produced." : transcript.text,
					matching: searchQuery
				))
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
				if let outputGenerationDuration = transcript.outputGenerationDuration {
					Label("Generated in \(formatElapsed(outputGenerationDuration))", systemImage: "timer")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		}
		.padding(12)
		.overlay(alignment: .bottom) { Divider() }
		.onHover { isHoveringTranscription = $0 }
		.accessibilityAction(named: "Show text only") {
			transcriptPresentation = .textOnly
		}
		.accessibilityAction(named: "Show timestamps and speaker labels") {
			transcriptPresentation = .timestampsAndSpeakerLabels
		}
	}

	private var transcriptPresentationControls: some View {
		HStack(spacing: 4) {
			transcriptPresentationButton(
				"Text only",
				systemImage: "arrow.down.right.and.arrow.up.left",
				presentation: .textOnly
			)
			transcriptPresentationButton(
				"With timestamps",
				systemImage: "clock",
				presentation: .timestampsAndSpeakerLabels
			)
		}
		.font(.caption)
		.opacity(shouldShowTranscriptPresentationControls ? 1 : 0)
		.animation(.easeInOut(duration: 0.15), value: shouldShowTranscriptPresentationControls)
	}

	private func transcriptPresentationButton(
		_ title: String,
		systemImage: String,
		presentation: TranscriptPresentation
	) -> some View {
		let isSelected = transcriptPresentation == presentation
		return Button {
			transcriptPresentation = presentation
		} label: {
			Label(title, systemImage: systemImage)
				.lineLimit(1)
				.padding(.horizontal, 7)
				.padding(.vertical, 4)
				.background(
					isSelected ? Color.accentColor.opacity(0.18) : .clear,
					in: Capsule()
				)
		}
		.buttonStyle(.plain)
		.foregroundStyle(isSelected ? .primary : .secondary)
		.focused($focusedTranscriptPresentation, equals: presentation)
		.help(title)
		.accessibilityLabel(title)
		.accessibilityValue(isSelected ? "Selected" : "Not selected")
	}

	@ViewBuilder
	private var transcriptPresentationContent: some View {
		switch transcriptPresentation {
		case .textOnly:
			Text(highlightedText(
				rawTranscript.isEmpty
					? (transcript.status == .processing ? "Transcription is still processing." : "No transcription was produced.")
					: rawTranscript,
				matching: searchQuery
			))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)

		case .timestampsAndSpeakerLabels:
			if timestampedSections.isEmpty {
				Text(highlightedText(
					rawTranscript.isEmpty
						? (transcript.status == .processing ? "Transcription is still processing." : "No transcription was produced.")
						: rawTranscript,
					matching: searchQuery
				))
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
				Label("Timestamps were not captured for this recording.", systemImage: "info.circle")
					.font(.caption)
					.foregroundStyle(.secondary)
			} else {
				VStack(alignment: .leading, spacing: 10) {
					ForEach(timestampedSections) { section in
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							Text("\(format(section.startTime))–\(format(section.endTime))")
								.font(.caption.monospacedDigit())
								.foregroundStyle(.secondary)
								.frame(width: 72, alignment: .leading)
							VStack(alignment: .leading, spacing: 2) {
								if let speakerName = speakerName(for: section) {
									if let profile = speakerProfile(for: section), profile.isUnknownSpeaker {
										Button(speakerName) {
											onOpenSpeaker(profile.id)
										}
										.buttonStyle(.plain)
										.font(.caption.weight(.semibold))
										.foregroundStyle(.secondary)
										.help("Name this speaker")
									} else {
										Text(speakerName)
											.font(.caption.weight(.semibold))
											.foregroundStyle(.secondary)
									}
								}
								Text(highlightedText(section.text, matching: searchQuery))
									.textSelection(.enabled)
									.fixedSize(horizontal: false, vertical: true)
							}
						}
					}
				}
			}
		}
	}

	private var footer: some View {
		HStack(spacing: 8) {
			metadata
			Spacer()
			if isRerunning { ProgressView().controlSize(.small) }
			Button(action: onCopy) { Image(systemName: "doc.on.doc.fill") }.buttonStyle(.plain).help("Copy result")
			Button(action: onRerunTranscription) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(isRerunning).help("Redo transcription")
			Button(action: onRerunFullRun) { Image(systemName: "arrow.triangle.2.circlepath") }.buttonStyle(.plain).disabled(isRerunning).help("Replay the full run")
			Button(action: onDelete) { Image(systemName: "trash.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete run")
		}
		.font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
	}

	private var metadata: some View {
		HStack(spacing: 6) {
			if let bundleID = transcript.sourceAppBundleID,
			   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
				Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path)).resizable().frame(width: 14, height: 14)
				Text(transcript.sourceAppName ?? appURL.deletingPathExtension().lastPathComponent)
				Text("•")
			}
			Image(systemName: "clock")
			Text(transcript.timestamp.relativeFormatted())
			Text("•")
			Text(transcript.timestamp.formatted(date: .omitted, time: .shortened))
		}
	}

	@ViewBuilder
	private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Label(title, systemImage: systemImage).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
			content()
		}.padding(12).overlay(alignment: .bottom) { Divider() }
	}

	private func format(_ time: TimeInterval) -> String { String(format: "%d:%02d", Int(time) / 60, Int(time) % 60) }
	private func formatElapsed(_ time: TimeInterval) -> String { String(format: "%.1fs", time) }
	private func formatMegabytes(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_000_000) }
}

private extension TranscriptProcessingStage {
	var displayName: String {
		switch self {
		case .audio: return "Audio"
		case .transcription: return "Transcription"
		case .selectedText: return "Selected text"
		case .screenContext: return "Screen context"
		case .processing: return "AI processing"
		}
	}
}

private extension TranscriptStatus {
	var historyLabel: String {
		switch self {
		case .completed: "Completed"
		case .processing: "Processing"
		case .cancelled: "Cancelled"
		case .failed: "Failed"
		}
	}

	var historySystemImage: String {
		switch self {
		case .completed: "checkmark.circle"
		case .processing: "ellipsis.circle"
		case .cancelled: "xmark.circle"
		case .failed: "exclamationmark.triangle.fill"
		}
	}
}

private extension ScreenAwareInputSource {
	var historyLabel: String {
		switch self {
		case .localOCR: "Local Apple Vision OCR"
		case .image: "Screenshot uploaded for analysis"
		}
	}

	var historySystemImage: String {
		switch self {
		case .localOCR: "text.viewfinder"
		case .image: "photo.badge.arrow.up"
		}
	}
}

struct HistoryView: View {
	@ObserveInjection var inject
	let store: StoreOf<HistoryFeature>
	let onOpenSpeaker: (UUID) -> Void
	@State private var showingDeleteConfirmation = false
	@State private var searchQuery = ""
	@State private var submittedSearchQuery = ""
	@State private var matchingTranscriptIDs: Set<UUID>?
	@State private var isSearching = false
	@State private var searchTask: Task<Void, Never>?
	@FocusState private var isSearchFieldFocused: Bool
	@Shared(.hexSettings) var hexSettings: HexSettings

	private var visibleTranscripts: [Transcript] {
		let runs = store.transcriptionHistory.history.filter { $0.isRefinementSource != true }
		guard let matchingTranscriptIDs else { return runs }
		return runs.filter { matchingTranscriptIDs.contains($0.id) }
	}

	var body: some View {
      Group {
        if !hexSettings.saveTranscriptionHistory {
          ContentUnavailableView {
            Label("History Disabled", systemImage: "clock.arrow.circlepath")
          } description: {
            Text("Transcription history is currently disabled.")
          } actions: {
            Button("Enable in Settings") {
              store.send(.navigateToSettings)
            }
          }
        } else if store.transcriptionHistory.history.isEmpty {
          ContentUnavailableView {
            Label("No Transcriptions", systemImage: "text.bubble")
          } description: {
            Text("Your transcription history will appear here.")
          }
		} else if isSearching {
			ContentUnavailableView {
				Label("Searching History", systemImage: "magnifyingglass")
			} description: {
				Text("Looking through your transcripts and results…")
			}
		} else {
			VStack(spacing: 0) {
				TextField("Search transcripts and results", text: $searchQuery)
					.textFieldStyle(.roundedBorder)
					.focused($isSearchFieldFocused)
					.onSubmit(searchHistory)
					.padding()

				if matchingTranscriptIDs != nil && visibleTranscripts.isEmpty {
					ContentUnavailableView.search(text: submittedSearchQuery)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(visibleTranscripts) { transcript in
                RunHistoryItemView(
                  transcript: transcript,
                  legacyRawTranscript: store.transcriptionHistory.history.first(where: {
                    $0.isRefinementSource == true && $0.audioPath == transcript.audioPath
                  })?.text,
                  isPlaying: store.playingTranscriptID == transcript.id && !store.isPlaybackPaused,
                  isPlaybackPaused: store.playingTranscriptID == transcript.id && store.isPlaybackPaused,
                  playbackProgress: store.playbackProgress,
                  playbackDuration: store.playbackDuration,
                  isRerunning: store.rerunningTranscriptIDs.contains(transcript.id),
                  onPlay: { store.send(.playTranscript(transcript.id)) },
                  onSeek: { store.send(.seekTranscript(transcript.id, $0)) },
                  onCopy: { store.send(.copyToClipboard(transcript.text)) },
				  onRerunTranscription: { store.send(.rerunTranscription(transcript.id)) },
				  onRerunFullRun: { store.send(.rerunFullRun(transcript.id)) },
					onDelete: { store.send(.deleteTranscript(transcript.id)) },
					onOpenSpeaker: onOpenSpeaker,
					searchQuery: matchingTranscriptIDs == nil ? "" : submittedSearchQuery
                )
              }
            }
            .padding()
          }
				}
			}
          .toolbar {
            Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
              Label("Delete All", systemImage: "trash")
            }
          }
          .alert("Delete All Transcripts", isPresented: $showingDeleteConfirmation) {
            Button("Delete All", role: .destructive) {
              store.send(.confirmDeleteAll)
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text("Are you sure you want to delete all transcripts? This action cannot be undone.")
          }
        }
      }.enableInjection()
	}

	private func searchHistory() {
		searchTask?.cancel()
		let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else {
			matchingTranscriptIDs = nil
			submittedSearchQuery = ""
			isSearching = false
			isSearchFieldFocused = true
			return
		}

		let history = store.transcriptionHistory.history
		submittedSearchQuery = query
		isSearching = true
		searchTask = Task {
			let matchingIDs = await Task.detached(priority: .userInitiated) {
				HistorySearch.matchingIDs(in: history, query: query)
			}.value
			guard !Task.isCancelled else { return }
			matchingTranscriptIDs = matchingIDs
			isSearching = false
			await Task.yield()
			guard !Task.isCancelled else { return }
			isSearchFieldFocused = true
		}
	}
}
