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

			let rawText: String
			do {
				rawText = try await transcription.transcribe(
					transcript.audioPath,
					settings.selectedModel,
					decodingOptions
				) { _ in }
			} catch {
				await send(.replayFailed(id, .transcription, error.localizedDescription))
				return
			}

			let shouldReprocess = includeProcessing && (
				transcript.wasRefined == true
				|| transcript.selectedText != nil
				|| transcript.screenshotPath != nil
			)
			guard shouldReprocess else {
				await send(.replaySucceeded(id, .init(rawText: rawText, outputText: rawText, wasRefined: false, outputGenerationDuration: nil)))
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
					history.history[index].wasRefined = result.wasRefined
					history.history[index].outputGenerationDuration = result.outputGenerationDuration
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
	let onSeek: (TimeInterval) -> Void
	@State private var samples: [CGFloat] = []

	var body: some View {
		VStack(spacing: 4) {
			Canvas { context, size in
				let bars = samples.isEmpty ? Array(repeating: CGFloat(0.22), count: 48) : samples
				let spacing: CGFloat = 2
				let width = max(1, (size.width - spacing * CGFloat(bars.count - 1)) / CGFloat(bars.count))
				let completed = duration > 0 ? progress / duration : 0
				for (index, sample) in bars.enumerated() {
					let height = max(3, size.height * sample)
					let x = CGFloat(index) * (width + spacing)
					let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
					let color: Color = CGFloat(index) / CGFloat(bars.count) <= completed ? .accentColor : .secondary.opacity(0.28)
					context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
				}
			}
			.frame(height: 34)

			Slider(
				value: Binding(get: { min(progress, max(0.01, duration)) }, set: onSeek),
				in: 0...max(0.01, duration)
			)
			.controlSize(.small)
		}
		.task(id: audioURL) {
			samples = await Task.detached(priority: .utility) {
				AudioWaveformSamples.load(from: audioURL)
			}.value
		}
	}
}

private struct RunHistoryItemView: View {
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

	private var rawTranscript: String { transcript.rawText ?? legacyRawTranscript ?? transcript.text }
	private var hasDistinctResult: Bool { transcript.text != rawTranscript || transcript.wasRefined == true }
	private var screenshotByteCount: Int? {
		if let screenshotByteCount = transcript.screenshotByteCount { return screenshotByteCount }
		return try? transcript.screenshotPath?.resourceValues(forKeys: [.fileSizeKey]).fileSize
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			section("Audio", systemImage: "waveform") {
				let audioProgress = isPlaying || isPlaybackPaused ? playbackProgress : 0
				let audioDuration = isPlaying || isPlaybackPaused ? playbackDuration : transcript.duration
				AudioWaveformView(audioURL: transcript.audioPath, progress: audioProgress, duration: audioDuration, onSeek: onSeek)
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

			section("Transcription", systemImage: "text.quote") {
				if let status = transcript.status, status != .completed {
					Label(status.historyLabel, systemImage: status.historySystemImage)
						.font(.caption.weight(.semibold))
						.foregroundStyle(status == .failed ? .red : .secondary)
				}
				Text(rawTranscript.isEmpty
					? (transcript.status == .processing ? "Transcription is still processing." : "No transcription was produced.")
					: rawTranscript)
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
				if hasDistinctResult {
					Divider().padding(.vertical, 4)
					Text("Result").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
					Text(transcript.text.isEmpty ? "No result was produced." : transcript.text)
						.textSelection(.enabled)
						.fixedSize(horizontal: false, vertical: true)
					if let outputGenerationDuration = transcript.outputGenerationDuration {
						Label("Generated in \(formatElapsed(outputGenerationDuration))", systemImage: "timer")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}

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
		.background(RoundedRectangle(cornerRadius: 8).fill(Color(.windowBackgroundColor).opacity(0.5)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)))
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
	@State private var showingDeleteConfirmation = false
	@Shared(.hexSettings) var hexSettings: HexSettings

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
        } else {
          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(store.transcriptionHistory.history.filter { $0.isRefinementSource != true }) { transcript in
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
                  onDelete: { store.send(.deleteTranscript(transcript.id)) }
                )
              }
            }
            .padding()
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
}
