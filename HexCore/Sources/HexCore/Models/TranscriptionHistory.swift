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
		processingErrors: [TranscriptProcessingError]? = nil,
		wasRefined: Bool? = nil,
		outputGenerationDuration: TimeInterval? = nil,
		screenshotByteCount: Int? = nil,
		screenAwareInputSource: ScreenAwareInputSource? = nil,
		recoverySessionID: UUID? = nil
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
		self.processingErrors = processingErrors
		self.wasRefined = wasRefined
		self.outputGenerationDuration = outputGenerationDuration
		self.screenshotByteCount = screenshotByteCount
		self.screenAwareInputSource = screenAwareInputSource
		self.recoverySessionID = recoverySessionID
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
