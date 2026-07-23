import Dependencies
import Foundation

public struct TranscriptPersistenceRequest: Sendable {
	public let text: String
	public let audioURL: URL
	public let duration: TimeInterval
	public let sourceAppBundleID: String?
	public let sourceAppName: String?
	public let status: TranscriptStatus
	public let screenshotData: Data?
	/// A screenshot that was durably staged before the audio checkpoint existed.
	public let screenshotPath: URL?
	public let rawText: String?
	public let selectedText: String?
	public let screenshotRecognizedText: String?
	public let processingErrors: [TranscriptProcessingError]?
	public let wasRefined: Bool?
	public let outputGenerationDuration: TimeInterval?
	public let screenAwareInputSource: ScreenAwareInputSource?

	public init(
		text: String,
		audioURL: URL,
		duration: TimeInterval,
		sourceAppBundleID: String?,
		sourceAppName: String?,
		status: TranscriptStatus,
		screenshotData: Data? = nil,
		screenshotPath: URL? = nil,
		rawText: String? = nil,
		selectedText: String? = nil,
		screenshotRecognizedText: String? = nil,
		processingErrors: [TranscriptProcessingError]? = nil,
		wasRefined: Bool? = nil,
		outputGenerationDuration: TimeInterval? = nil,
		screenAwareInputSource: ScreenAwareInputSource? = nil
	) {
		self.text = text
		self.audioURL = audioURL
		self.duration = duration
		self.sourceAppBundleID = sourceAppBundleID
		self.sourceAppName = sourceAppName
		self.status = status
		self.screenshotData = screenshotData
		self.screenshotPath = screenshotPath
		self.rawText = rawText
		self.selectedText = selectedText
		self.screenshotRecognizedText = screenshotRecognizedText
		self.processingErrors = processingErrors
		self.wasRefined = wasRefined
		self.outputGenerationDuration = outputGenerationDuration
		self.screenAwareInputSource = screenAwareInputSource
	}
}

public struct TranscriptPersistenceClient: Sendable {
	public var save: @Sendable (_ request: TranscriptPersistenceRequest) async throws -> Transcript
	public var saveScreenshot: @Sendable (_ imagePNGData: Data) async throws -> URL
	public var deleteArtifacts: @Sendable (_ transcript: Transcript) async throws -> Void
}

extension TranscriptPersistenceClient: DependencyKey {
    public static let liveValue: TranscriptPersistenceClient = {
        return TranscriptPersistenceClient(
            save: { request in
                let fm = FileManager.default
                let recordingsFolder = try URL.hexApplicationSupport.appendingPathComponent("Recordings", isDirectory: true)
                try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)

				let identifier = UUID().uuidString
				let recoverySessionID = recoverySessionID(for: request.audioURL, recordingsFolder: recordingsFolder)
				let finalURL = recoverySessionID == nil
					? recordingsFolder.appendingPathComponent("\(identifier).wav")
					: request.audioURL
				let screenshotURL: URL?
				let ownsScreenshotArtifact: Bool
				if let screenshotPath = request.screenshotPath {
					screenshotURL = screenshotPath
					ownsScreenshotArtifact = false
				} else if let screenshotData = request.screenshotData {
					let screenshotsFolder = try URL.hexApplicationSupport.appendingPathComponent("Screenshots", isDirectory: true)
					try fm.createDirectory(at: screenshotsFolder, withIntermediateDirectories: true)
					let url = screenshotsFolder.appendingPathComponent("\(identifier).png")
					try screenshotData.write(to: url, options: .atomic)
					screenshotURL = url
					ownsScreenshotArtifact = true
				} else {
					screenshotURL = nil
					ownsScreenshotArtifact = false
				}

				if recoverySessionID == nil {
					do {
						try fm.moveItem(at: request.audioURL, to: finalURL)
					} catch {
						if ownsScreenshotArtifact, let screenshotURL { try? fm.removeItem(at: screenshotURL) }
						throw error
					}
				}
                
				let screenshotByteCount: Int?
				if let screenshotData = request.screenshotData {
					screenshotByteCount = screenshotData.count
				} else if let screenshotURL {
					screenshotByteCount = try? screenshotURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
				} else {
					screenshotByteCount = nil
				}
				return Transcript(
                    timestamp: Date(),
                    text: request.text,
                    audioPath: finalURL,
					duration: request.duration,
					sourceAppBundleID: request.sourceAppBundleID,
					sourceAppName: request.sourceAppName,
					status: request.status,
					screenshotPath: screenshotURL,
					rawText: request.rawText,
					selectedText: request.selectedText,
					screenshotRecognizedText: request.screenshotRecognizedText,
					processingErrors: request.processingErrors,
					wasRefined: request.wasRefined,
					outputGenerationDuration: request.outputGenerationDuration,
					screenshotByteCount: screenshotByteCount,
					screenAwareInputSource: request.screenAwareInputSource,
					recoverySessionID: recoverySessionID
                )
			},
			saveScreenshot: { imagePNGData in
				let fm = FileManager.default
				let screenshotsFolder = try URL.hexApplicationSupport.appendingPathComponent("Screenshots", isDirectory: true)
				try fm.createDirectory(at: screenshotsFolder, withIntermediateDirectories: true)
				let url = screenshotsFolder.appendingPathComponent("\(UUID().uuidString).png")
				try imagePNGData.write(to: url, options: .atomic)
				return url
			},
			deleteArtifacts: { transcript in
				try? FileManager.default.removeItem(at: transcript.audioPath)
				if let screenshotPath = transcript.screenshotPath {
					try? FileManager.default.removeItem(at: screenshotPath)
				}
            }
        )
    }()
    
    public static let testValue = TranscriptPersistenceClient(
		save: { _ in
            Transcript(timestamp: Date(), text: "", audioPath: URL(fileURLWithPath: "/"), duration: 0)
        },
		saveScreenshot: { _ in URL(fileURLWithPath: "/") },
		deleteArtifacts: { _ in }
    )
}

private func recoverySessionID(for audioURL: URL, recordingsFolder: URL) -> UUID? {
	guard audioURL.deletingLastPathComponent().standardizedFileURL == recordingsFolder.standardizedFileURL,
		  audioURL.pathExtension == "wav"
	else { return nil }
	let prefix = "active-"
	let name = audioURL.deletingPathExtension().lastPathComponent
	guard name.hasPrefix(prefix) else { return nil }
	return UUID(uuidString: String(name.dropFirst(prefix.count)))
}

public extension DependencyValues {
    var transcriptPersistence: TranscriptPersistenceClient {
        get { self[TranscriptPersistenceClient.self] }
        set { self[TranscriptPersistenceClient.self] = newValue }
    }
}
