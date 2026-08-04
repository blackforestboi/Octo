import Foundation

public enum TranscriptStatus: String, Codable, Equatable, Sendable {
	case processing
    case completed
    case cancelled
    case failed
}

public enum TranscriptProcessingStage: String, Codable, CaseIterable, Equatable, Sendable {
	case audio
	case transcription
	case selectedText
	case screenContext
	case processing
}

/// The independently captured audio input that produced a transcript channel.
///
/// A recording can include both the user's microphone and system playback. Keeping
/// the source alongside the channel lets History preserve each recording and still
/// render their timed sections as one conversation.
public enum TranscriptAudioSource: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
	case microphone
	case systemAudio

	public var id: Self { self }

	public var displayName: String {
		switch self {
		case .microphone: "Microphone"
		case .systemAudio: "System Audio"
		}
	}
}

/// One independently captured and transcribed audio stream in a recording.
public struct TranscriptAudioChannel: Codable, Equatable, Identifiable, Sendable {
	public var source: TranscriptAudioSource
	public var audioPath: URL
	public var duration: TimeInterval
	/// Offset from the microphone recording's start, used only when merging channels for display.
	public var startOffset: TimeInterval
	public var text: String
	public var timestampedSections: [TimestampedTranscriptSection]?
	public var speakerSegments: [SpeakerAttributedSegment]?
	public var liveCheckpoint: SourceLiveTranscriptCheckpoint?

	public var id: TranscriptAudioSource { source }

	public init(
		source: TranscriptAudioSource,
		audioPath: URL,
		duration: TimeInterval,
		startOffset: TimeInterval = 0,
		text: String = "",
		timestampedSections: [TimestampedTranscriptSection]? = nil,
		speakerSegments: [SpeakerAttributedSegment]? = nil,
		liveCheckpoint: SourceLiveTranscriptCheckpoint? = nil
	) {
		self.source = source
		self.audioPath = audioPath
		self.duration = duration
		self.startOffset = startOffset
		self.text = text
		self.timestampedSections = timestampedSections
		self.speakerSegments = speakerSegments
		self.liveCheckpoint = liveCheckpoint
	}
}

public struct TranscriptProcessingError: Codable, Equatable, Sendable, Identifiable {
	public var id: UUID
	public var stage: TranscriptProcessingStage
	public var message: String
	public var timestamp: Date

	public init(
		id: UUID = UUID(),
		stage: TranscriptProcessingStage,
		message: String,
		timestamp: Date = Date()
	) {
		self.id = id
		self.stage = stage
		self.message = message
		self.timestamp = timestamp
	}
}

public struct Transcript: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var text: String
    public var audioPath: URL
    public var duration: TimeInterval
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
	public var status: TranscriptStatus?
	public var isRefinementSource: Bool?
	public var screenshotPath: URL?
	/// The locally transcribed request before optional AI processing.
	public var rawText: String?
	/// The selected text supplied to refinement, when any.
	public var selectedText: String?
	/// Locally recognized text from the stored screenshot.
	public var screenshotRecognizedText: String?
	/// Timestamped sentence sections captured by a timing-capable ASR provider.
	public var timestampedSections: [TimestampedTranscriptSection]?
	/// Timed, local speaker labels when speaker identification was enabled for this recording.
	public var speakerSegments: [SpeakerAttributedSegment]?
	/// The microphone and, when enabled, system-audio streams retained independently.
	/// Older recordings decode without this field and continue to use the legacy top-level fields.
	public var audioChannels: [TranscriptAudioChannel]?
	/// Diagnostics retained with the run so failures are inspectable and retryable.
	public var processingErrors: [TranscriptProcessingError]?
	/// Whether this run included an AI processing step after transcription.
	public var wasRefined: Bool?
	/// Elapsed time spent generating the processed output, when applicable.
	public var outputGenerationDuration: TimeInterval?
	/// Exact byte count of the persisted screenshot, when the run has screen context.
	public var screenshotByteCount: Int?
	/// The screen context source used for this run, retained for an accurate full rerun.
	public var screenAwareInputSource: ScreenAwareInputSource?
	/// Identifies audio reconstructed after an interrupted recording so it can be recovered
	/// without being pasted as if it were a completed transcript.
	public var recoverySessionID: UUID?
	/// Identifies takes that belong to the same user-managed recording session.
	/// The field is optional so existing History files remain fully compatible.
	public var recordingSessionID: UUID?
	/// The title the user sees for a recording session. It is repeated on each take so
	/// a future History grouping can recover the session without another storage file.
	public var recordingSessionTitle: String?
	/// Stable identities referenced by committed live transcript sections.
	public var sessionSpeakers: [SessionSpeaker]?
	/// Monotonic live-transcription state. The provisional tail is intentionally absent.
	public var liveTranscriptCheckpoint: LiveTranscriptCheckpoint?
	/// Snapshotted live speaker settings used to drain a recovered tail consistently.
	public var liveSpeakerIdentificationEnabled: Bool?
	public var liveSpeakerDiarizationMode: SpeakerDiarizationMode?
    
    public init(
        id: UUID = UUID(),
        timestamp: Date,
        text: String,
        audioPath: URL,
        duration: TimeInterval,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
		status: TranscriptStatus? = nil,
		isRefinementSource: Bool? = nil,
		screenshotPath: URL? = nil,
		rawText: String? = nil,
		selectedText: String? = nil,
		screenshotRecognizedText: String? = nil,
		timestampedSections: [TimestampedTranscriptSection]? = nil,
		speakerSegments: [SpeakerAttributedSegment]? = nil,
		audioChannels: [TranscriptAudioChannel]? = nil,
		processingErrors: [TranscriptProcessingError]? = nil,
		wasRefined: Bool? = nil,
		outputGenerationDuration: TimeInterval? = nil,
		screenshotByteCount: Int? = nil,
		screenAwareInputSource: ScreenAwareInputSource? = nil,
		recoverySessionID: UUID? = nil,
		recordingSessionID: UUID? = nil,
		recordingSessionTitle: String? = nil,
		sessionSpeakers: [SessionSpeaker]? = nil,
		liveTranscriptCheckpoint: LiveTranscriptCheckpoint? = nil,
		liveSpeakerIdentificationEnabled: Bool? = nil,
		liveSpeakerDiarizationMode: SpeakerDiarizationMode? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.audioPath = audioPath
        self.duration = duration
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.status = status
		self.isRefinementSource = isRefinementSource
		self.screenshotPath = screenshotPath
		self.rawText = rawText
		self.selectedText = selectedText
		self.screenshotRecognizedText = screenshotRecognizedText
		self.timestampedSections = timestampedSections
		self.speakerSegments = speakerSegments
		self.audioChannels = audioChannels
		self.processingErrors = processingErrors
		self.wasRefined = wasRefined
		self.outputGenerationDuration = outputGenerationDuration
		self.screenshotByteCount = screenshotByteCount
		self.screenAwareInputSource = screenAwareInputSource
		self.recoverySessionID = recoverySessionID
		self.recordingSessionID = recordingSessionID
		self.recordingSessionTitle = recordingSessionTitle
		self.sessionSpeakers = sessionSpeakers
		self.liveTranscriptCheckpoint = liveTranscriptCheckpoint
		self.liveSpeakerIdentificationEnabled = liveSpeakerIdentificationEnabled
		self.liveSpeakerDiarizationMode = liveSpeakerDiarizationMode
    }
}

public struct TranscriptionHistory: Codable, Equatable, Sendable {
    public var history: [Transcript] = []

	/// The most recent non-recovery transcript with text, regardless of array order.
	public var latestPasteableTranscriptText: String? {
		history
			.filter { $0.recoverySessionID == nil && !$0.text.isEmpty }
			.max { $0.timestamp < $1.timestamp }?
			.text
	}
    
    public init(history: [Transcript] = []) {
        self.history = history
    }
}
