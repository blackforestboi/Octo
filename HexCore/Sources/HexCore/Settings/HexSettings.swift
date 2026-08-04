import Foundation

public enum RecordingAudioBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	case pauseMedia
	case mute
	case doNothing
}

public enum IndicatorSize: String, Codable, CaseIterable, Equatable, Sendable {
	case compact
	case regular
	case large

	public var displayName: String {
		switch self {
		case .compact: "Compact"
		case .regular: "Regular"
		case .large: "Large"
		}
	}
}

public enum IndicatorLocation: String, Codable, CaseIterable, Equatable, Sendable {
	case topLeading
	case topCenter
	case topTrailing
	case bottomLeading
	case bottomCenter
	case bottomTrailing

	public var displayName: String {
		switch self {
		case .topLeading: "Top Left"
		case .topCenter: "Top Center"
		case .topTrailing: "Top Right"
		case .bottomLeading: "Bottom Left"
		case .bottomCenter: "Bottom Center"
		case .bottomTrailing: "Bottom Right"
		}
	}
}

/// A named instruction set that can be selected with a long-held number key
/// while finishing a recording.
public struct RewritePrompt: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var name: String
	public var instructions: String

	public init(id: UUID = UUID(), name: String, instructions: String) {
		self.id = id
		self.name = name
		self.instructions = instructions
	}
}

/// User-configurable settings saved to disk.
public struct HexSettings: Codable, Equatable, Sendable {
	public static let defaultPasteLastTranscriptHotkey = HotKey(key: .v, modifiers: [.option, .shift])
	public static let baseSoundEffectsVolume: Double = HexCoreConstants.baseSoundEffectsVolume
	public static let maximumRewritePrompts = 9
	public static let defaultRewritePromptName = "Default"
	public static let defaultWordRemovals: [WordRemoval] = [
		.init(pattern: "uh+"),
		.init(pattern: "um+"),
		.init(pattern: "er+"),
		.init(pattern: "hm+")
	]
	public static let defaultRefinementInstructions = """
	# Voice Memo Refinement Guidelines

	- Stay faithful to the source: don't invent details, don't omit any, keep the qualitative language and context that carries meaning.
	- Match the requested tone/style; default to casual if none is given.
	- Use bullets or numbered lists for any list of items, unless told otherwise.
	- Organize into clear paragraphs and cut filler words that don't change the meaning.

	# Human Writing Style

	- **No em-dashes or dashes to segment sentences.** Use two shorter sentences instead.
	- Be specific. Concrete facts beat vague praise.
	- Use simple verbs: is, has, was, did. Not "serves as," "boasts," "showcases."
	- Skip cheerleading and forced significance. State facts; don't explain why they matter or claim they "reflect broader trends."
	- Repeat words when needed instead of cycling synonyms.
	- Short sentences are fine. Not everything needs three clauses.
	- Attribute opinions to a specific person ("Roger Ebert wrote...") not a vague group ("experts say...").
	- Use lowercase headings. Title case reads as AI-generated.
	- Bold sparingly.
	- Use contractions: it's, don't, won't.
	- Avoid AI tells: stock vocabulary (delve, pivotal, tapestry), "-ing" phrases tacked onto sentence ends, "despite challenges..." formulas, and rule-of-three lists.
	"""

	public static var defaultPasteLastTranscriptHotkeyDescription: String {
		let modifiers = defaultPasteLastTranscriptHotkey.modifiers.sorted.map { $0.stringValue }.joined()
		let key = defaultPasteLastTranscriptHotkey.key?.toString ?? ""
		return modifiers + key
	}

	public var soundEffectsEnabled: Bool
	public var soundEffectsVolume: Double
	public var hotkey: HotKey
	public var openOnLogin: Bool
	public var showDockIcon: Bool
	public var indicatorSize: IndicatorSize
	public var indicatorLocation: IndicatorLocation
	public var selectedModel: String
	public var useClipboardPaste: Bool
	public var preventSystemSleep: Bool
	public var recordingAudioBehavior: RecordingAudioBehavior
	public var minimumKeyTime: Double
	public var stopDelayMilliseconds: Int
	public var longRecordingConfirmationThresholdMinutes: Int
	public var copyToClipboard: Bool
	public var superFastModeEnabled: Bool
	public var useDoubleTapOnly: Bool
	public var allowLongPressForOnDemand: Bool
	public var doubleTapLockEnabled: Bool
	public var outputLanguage: String?
	public var selectedMicrophoneID: String?
	public var saveTranscriptionHistory: Bool
	public var maxHistoryEntries: Int?
	public var pasteLastTranscriptHotkey: HotKey?
	public var hasCompletedModelBootstrap: Bool
	public var hasCompletedStorageMigration: Bool
	public var wordRemovalsEnabled: Bool
	public var wordRemovals: [WordRemoval]
	public var wordRemappings: [WordRemapping]
	public var lowercaseTranscripts: Bool
	public var removePunctuation: Bool
	/// Enables a second, local pass that assigns speaker labels to timed transcript words.
	public var speakerIdentificationEnabled: Bool
	/// Default for delayed, durable transcription in newly-created Recording Sessions.
	public var liveTranscriptionEnabled: Bool
	/// Capacity/accuracy mode snapshotted for a Recording Session.
	public var speakerDiarizationMode: SpeakerDiarizationMode
	/// Captures system playback as a second, independently transcribed audio stream.
	public var includeSystemAudio: Bool
	/// The local diarization implementation. Keeping this preference explicit makes
	/// future on-device providers a settings change rather than a data migration.
	public var speakerDiarizationProvider: SpeakerDiarizationProvider
	/// Optional post-processing is deliberately separate from the transcription pipeline.
	public var refinementMode: RefinementMode
	/// Enables all optional transcript-refinement workflows and controls.
	public var refinementEnabled: Bool
	public var refinementProvider: RefinementProvider
	/// Controls how much reasoning the refinement provider should use when supported.
	public var refinementReasoningEffort: RefinementReasoningEffort
	/// The local subscription CLI that receives Agent Handoff tasks.
	/// Agent Handoffs can only be launched through Codex or Claude Code.
	public var agentHandoffProvider: RefinementProvider
	/// Enables Agent Handoff workflows and controls independently of refinement.
	public var agentHandoffEnabled: Bool
	/// A model selection dedicated to Agent Handoffs, separate from quick refinement.
	public var agentHandoffModelID: String?
	/// Controls how much reasoning Agent Handoff workflows request when supported.
	public var agentHandoffReasoningEffort: RefinementReasoningEffort
	/// Prevents a one-time fresh-install check from overriding a user's provider choice later.
	public var hasCompletedRefinementProviderDetection: Bool
	/// Model selections are kept per provider so changing providers never reuses an incompatible ID.
	public var openAIModelID: String?
	public var anthropicModelID: String?
	public var codexCLIModelID: String?
	public var claudeCLIModelID: String?
	/// User-authored instructions appended to Hex's refinement contract.
	public var refinementInstructions: String
	/// Named rewrite instructions. Their one-based positions map to long-held number keys.
	public var rewritePrompts: [RewritePrompt]
	public var openRouterModelID: String?
	/// OpenRouter models promoted to the short list shown in the model picker and menu bar.
	public var openRouterShortlistedModelIDs: [String]
	/// Vision-capable OpenRouter model used only when the selected refinement model
	/// cannot accept an uploaded screenshot.
	public var screenAwareOpenRouterModelID: String?
	/// Keeps the selected Screen Aware model while allowing the feature to be disabled.
	public var screenAwareDictationEnabled: Bool
	/// Chooses whether Screen Aware sends a screenshot to OpenRouter or uses local OCR only.
	public var screenAwareInputSource: ScreenAwareInputSource
	/// Whether recording captures selected text as refinement source material.
	public var includeSelectedTextInRefinement: Bool

	public var isScreenAwareDictationConfigured: Bool {
		screenAwareDictationEnabled
	}

	public var hasScreenAwareImageFallbackModel: Bool {
		guard let screenAwareOpenRouterModelID else { return false }
		return !screenAwareOpenRouterModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	public func rewritePrompt(at oneBasedIndex: Int) -> RewritePrompt? {
		guard rewritePrompts.indices.contains(oneBasedIndex - 1) else { return nil }
		return rewritePrompts[oneBasedIndex - 1]
	}

	private var defaultRewritePrompt: RewritePrompt {
		rewritePrompts.first ?? .init(
			name: Self.defaultRewritePromptName,
			instructions: refinementInstructions
		)
	}

	public func refinementRequest(
		for text: String,
		mode: RefinementMode,
		spokenInstruction: String? = nil,
		rewritePrompt: RewritePrompt? = nil
	) -> RefinementRequest {
		let spokenInstruction = spokenInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		if mode == .speakerIntroduction {
			return .init(
				text: text,
				mode: mode,
				instructions: "",
				provider: refinementProvider,
				reasoningEffort: .none,
				modelID: selectedRefinementModelID
			)
		}
		let prompt = rewritePrompt ?? defaultRewritePrompt
		var instructionParts = [prompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines)]
		if !spokenInstruction.isEmpty {
			instructionParts.append("Spoken instruction:\n\(spokenInstruction)")
		}
		instructionParts.removeAll { $0.isEmpty }
		let instructions = instructionParts.joined(separator: "\n\n")

		return .init(
			text: text,
			mode: mode,
			instructions: instructions,
			provider: refinementProvider,
			reasoningEffort: refinementReasoningEffort,
			modelID: selectedRefinementModelID
			)
		}

		public func screenAwareRequest(
			for spokenRequest: String,
			context: ScreenContext,
			inputSource: ScreenAwareInputSource? = nil,
			imageModelID: String? = nil
		) -> RefinementRequest {
			let inputSource = inputSource ?? screenAwareInputSource
			let usesUploadedImage = inputSource.uploadsScreenshot
			return RefinementRequest(
				text: spokenRequest,
				mode: .refined,
			instructions: defaultRewritePrompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
			provider: usesUploadedImage && !refinementProvider.supportsImageInput ? .openRouter : refinementProvider,
			reasoningEffort: refinementReasoningEffort,
			modelID: usesUploadedImage ? (imageModelID ?? screenAwareOpenRouterModelID) : selectedRefinementModelID,
				screenContext: context,
				screenAwareInputSource: inputSource
			)
		}

	private mutating func normalizeDoubleTapSettings() {
		if !doubleTapLockEnabled {
			useDoubleTapOnly = false
		}
	}

	public var selectedRefinementModelID: String? {
		switch refinementProvider {
		case .openRouter:
			openRouterModelID
		case .openAI:
			openAIModelID ?? openRouterModelID // Retains selections made before per-provider storage.
		case .anthropic:
			anthropicModelID ?? openRouterModelID // Retains selections made before per-provider storage.
		case .codexCLI:
			codexCLIModelID
		case .claudeCLI:
			claudeCLIModelID
		case .apple, .gemini:
			nil
		}
	}

	public init(
		soundEffectsEnabled: Bool = true,
		soundEffectsVolume: Double = HexSettings.baseSoundEffectsVolume,
		hotkey: HotKey = .init(key: nil, modifiers: [.control]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		indicatorSize: IndicatorSize = .regular,
		indicatorLocation: IndicatorLocation = .topCenter,
		selectedModel: String = ParakeetModel.multilingualV3.identifier,
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		recordingAudioBehavior: RecordingAudioBehavior = .doNothing,
		minimumKeyTime: Double = HexCoreConstants.defaultMinimumKeyTime,
		stopDelayMilliseconds: Int = 0,
		longRecordingConfirmationThresholdMinutes: Int = 1,
		copyToClipboard: Bool = false,
		superFastModeEnabled: Bool = true,
		useDoubleTapOnly: Bool = true,
		allowLongPressForOnDemand: Bool = true,
		doubleTapLockEnabled: Bool = true,
		outputLanguage: String? = nil,
		selectedMicrophoneID: String? = nil,
		saveTranscriptionHistory: Bool = true,
		maxHistoryEntries: Int? = nil,
		pasteLastTranscriptHotkey: HotKey? = HexSettings.defaultPasteLastTranscriptHotkey,
		hasCompletedModelBootstrap: Bool = false,
		hasCompletedStorageMigration: Bool = false,
		wordRemovalsEnabled: Bool = false,
		wordRemovals: [WordRemoval] = HexSettings.defaultWordRemovals,
		wordRemappings: [WordRemapping] = [],
		lowercaseTranscripts: Bool = false,
		removePunctuation: Bool = false,
		speakerIdentificationEnabled: Bool = false,
		liveTranscriptionEnabled: Bool = true,
		speakerDiarizationMode: SpeakerDiarizationMode = .highAccuracyFour,
		includeSystemAudio: Bool = false,
		speakerDiarizationProvider: SpeakerDiarizationProvider = .fluidAudio,
		refinementMode: RefinementMode = .raw,
		refinementEnabled: Bool = true,
		refinementProvider: RefinementProvider = .apple,
		refinementReasoningEffort: RefinementReasoningEffort = .none,
		agentHandoffProvider: RefinementProvider = .codexCLI,
		agentHandoffEnabled: Bool = false,
		agentHandoffModelID: String? = nil,
		agentHandoffReasoningEffort: RefinementReasoningEffort = .medium,
		hasCompletedRefinementProviderDetection: Bool = false,
		openAIModelID: String? = nil,
		anthropicModelID: String? = nil,
		codexCLIModelID: String? = nil,
		claudeCLIModelID: String? = nil,
			refinementInstructions: String = HexSettings.defaultRefinementInstructions,
		rewritePrompts: [RewritePrompt]? = nil,
		openRouterModelID: String? = nil,
		openRouterShortlistedModelIDs: [String] = [],
		screenAwareOpenRouterModelID: String? = nil,
			screenAwareDictationEnabled: Bool = false,
			screenAwareInputSource: ScreenAwareInputSource = .localOCR,
		includeSelectedTextInRefinement: Bool = true
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.soundEffectsVolume = soundEffectsVolume
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.indicatorSize = indicatorSize
		self.indicatorLocation = indicatorLocation
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.recordingAudioBehavior = recordingAudioBehavior
		self.minimumKeyTime = minimumKeyTime
		self.stopDelayMilliseconds = max(0, stopDelayMilliseconds)
		self.longRecordingConfirmationThresholdMinutes = max(1, longRecordingConfirmationThresholdMinutes)
		self.copyToClipboard = copyToClipboard
		self.superFastModeEnabled = superFastModeEnabled
		self.useDoubleTapOnly = useDoubleTapOnly
		self.allowLongPressForOnDemand = allowLongPressForOnDemand
		self.doubleTapLockEnabled = doubleTapLockEnabled
		self.outputLanguage = outputLanguage
		self.selectedMicrophoneID = selectedMicrophoneID
		self.saveTranscriptionHistory = saveTranscriptionHistory
		self.maxHistoryEntries = maxHistoryEntries
		self.pasteLastTranscriptHotkey = pasteLastTranscriptHotkey
		self.hasCompletedModelBootstrap = hasCompletedModelBootstrap
		self.hasCompletedStorageMigration = hasCompletedStorageMigration
		self.wordRemovalsEnabled = wordRemovalsEnabled
		self.wordRemovals = wordRemovals
		self.wordRemappings = wordRemappings
		self.lowercaseTranscripts = lowercaseTranscripts
		self.removePunctuation = removePunctuation
		self.speakerIdentificationEnabled = speakerIdentificationEnabled
		self.liveTranscriptionEnabled = liveTranscriptionEnabled
		self.speakerDiarizationMode = speakerDiarizationMode
		self.includeSystemAudio = includeSystemAudio
		self.speakerDiarizationProvider = speakerDiarizationProvider
		self.refinementMode = refinementMode
		self.refinementEnabled = refinementEnabled
		self.refinementProvider = refinementProvider
		self.refinementReasoningEffort = refinementReasoningEffort
		self.agentHandoffProvider = agentHandoffProvider.handoffProvider ?? .codexCLI
		self.agentHandoffEnabled = agentHandoffEnabled
		self.agentHandoffModelID = agentHandoffModelID
		self.agentHandoffReasoningEffort = agentHandoffReasoningEffort
		self.hasCompletedRefinementProviderDetection = hasCompletedRefinementProviderDetection
		self.openAIModelID = openAIModelID
		self.anthropicModelID = anthropicModelID
		self.codexCLIModelID = codexCLIModelID
		self.claudeCLIModelID = claudeCLIModelID
			self.refinementInstructions = refinementInstructions
			let prompts = rewritePrompts ?? [.init(
				name: Self.defaultRewritePromptName,
				instructions: refinementInstructions
			)]
			self.rewritePrompts = Array(prompts.prefix(Self.maximumRewritePrompts))
			if self.rewritePrompts.isEmpty {
				self.rewritePrompts = [.init(
					name: Self.defaultRewritePromptName,
					instructions: refinementInstructions
				)]
		}
		self.openRouterModelID = openRouterModelID
		self.openRouterShortlistedModelIDs = openRouterShortlistedModelIDs.reduce(into: []) { ids, modelID in
			if !ids.contains(modelID) {
				ids.append(modelID)
			}
		}
		self.screenAwareOpenRouterModelID = screenAwareOpenRouterModelID
			self.screenAwareDictationEnabled = screenAwareDictationEnabled
			self.screenAwareInputSource = screenAwareInputSource
		self.includeSelectedTextInRefinement = includeSelectedTextInRefinement
		normalizeDoubleTapSettings()
	}

	public init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: HexSettingKey.self)
	let hasStoredRefinementProviderDetection = container.contains(.hasCompletedRefinementProviderDetection)
	for field in HexSettingsSchema.fields {
		try field.decode(into: &self, from: container)
	}
	if !container.contains(.agentHandoffProvider) {
		agentHandoffProvider = refinementProvider.handoffProvider ?? .codexCLI
	}
	if !container.contains(.agentHandoffModelID) {
		agentHandoffModelID = agentHandoffProvider == refinementProvider ? selectedRefinementModelID : nil
	}
	if !container.contains(.agentHandoffReasoningEffort) {
		agentHandoffReasoningEffort = .medium
	}
		// Versions before named rewrite prompts stored one instruction string. Keep that
		// exact string as the first prompt so existing refinements remain unchanged.
		if !container.contains(.rewritePrompts) || rewritePrompts.isEmpty {
			rewritePrompts = [.init(
				name: Self.defaultRewritePromptName,
				instructions: refinementInstructions
			)]
		} else {
			rewritePrompts = Array(rewritePrompts.prefix(Self.maximumRewritePrompts))
		}
		// Existing installations already have a provider choice. Only a fresh
		// settings store should receive the automatic subscription selection.
		if !hasStoredRefinementProviderDetection {
			hasCompletedRefinementProviderDetection = true
		}
		normalizeDoubleTapSettings()
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.encode(self, into: &container)
		}
	}
}

private extension RefinementProvider {
	var supportsImageInput: Bool {
		switch self {
		case .openRouter, .openAI, .anthropic:
			true
		case .apple, .gemini, .codexCLI, .claudeCLI:
			false
		}
	}
}

// MARK: - Schema

private enum HexSettingKey: String, CodingKey, CaseIterable {
	case soundEffectsEnabled
	case soundEffectsVolume
	case hotkey
	case openOnLogin
	case showDockIcon
	case indicatorSize
	case indicatorLocation
	case selectedModel
	case useClipboardPaste
	case preventSystemSleep
	case recordingAudioBehavior
	case pauseMediaOnRecord // Legacy
	case minimumKeyTime
	case stopDelayMilliseconds
	case longRecordingConfirmationThresholdMinutes
	case copyToClipboard
	case superFastModeEnabled
	case useDoubleTapOnly
	case allowLongPressForOnDemand
	case doubleTapLockEnabled
	case outputLanguage
	case selectedMicrophoneID
	case saveTranscriptionHistory
	case maxHistoryEntries
	case pasteLastTranscriptHotkey
	case hasCompletedModelBootstrap
	case hasCompletedStorageMigration
	case wordRemovalsEnabled
	case wordRemovals
	case wordRemappings
	case lowercaseTranscripts
	case removePunctuation
	case speakerIdentificationEnabled
	case liveTranscriptionEnabled
	case speakerDiarizationMode
	case includeSystemAudio
	case speakerDiarizationProvider
	case refinementMode
	case refinementEnabled
	case refinementProvider
	case refinementReasoningEffort
	case agentHandoffProvider
	case agentHandoffEnabled
	case agentHandoffModelID
	case agentHandoffReasoningEffort
	case hasCompletedRefinementProviderDetection
	case openAIModelID
	case anthropicModelID
	case codexCLIModelID
	case claudeCLIModelID
	case refinementInstructions
	case rewritePrompts
		case openRouterModelID
		case openRouterShortlistedModelIDs
		case screenAwareOpenRouterModelID
		case screenAwareDictationEnabled
		case screenAwareInputSource
	case includeSelectedTextInRefinement
}

private struct SettingsField<Value: Codable & Sendable> {
	let key: HexSettingKey
	let keyPath: WritableKeyPath<HexSettings, Value>
	let defaultValue: Value
	let decodeStrategy: (KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value
	let encodeStrategy: (inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void

	init(
		_ key: HexSettingKey,
		keyPath: WritableKeyPath<HexSettings, Value>,
		default defaultValue: Value,
		decode: ((KeyedDecodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Value)? = nil,
		encode: ((inout KeyedEncodingContainer<HexSettingKey>, HexSettingKey, Value) throws -> Void)? = nil
	) {
		self.key = key
		self.keyPath = keyPath
		self.defaultValue = defaultValue
		self.decodeStrategy = decode ?? { container, key, defaultValue in
			try container.decodeIfPresent(Value.self, forKey: key) ?? defaultValue
		}
		self.encodeStrategy = encode ?? { container, key, value in
			try container.encode(value, forKey: key)
		}
	}

	func eraseToAny() -> AnySettingsField {
		AnySettingsField(
			key: key,
			decode: { container, settings in
				let value = try decodeStrategy(container, key, defaultValue)
				settings[keyPath: keyPath] = value
			},
			encode: { settings, container in
				let value = settings[keyPath: keyPath]
				try encodeStrategy(&container, key, value)
			}
		)
	}
}

private struct AnySettingsField {
	let key: HexSettingKey
	let decode: (KeyedDecodingContainer<HexSettingKey>, inout HexSettings) throws -> Void
	let encode: (HexSettings, inout KeyedEncodingContainer<HexSettingKey>) throws -> Void

	func decode(into settings: inout HexSettings, from container: KeyedDecodingContainer<HexSettingKey>) throws {
		try decode(container, &settings)
	}

	func encode(_ settings: HexSettings, into container: inout KeyedEncodingContainer<HexSettingKey>) throws {
		try encode(settings, &container)
	}
}

private enum HexSettingsSchema {
	static let defaults = HexSettings()

	nonisolated(unsafe) static let fields: [AnySettingsField] = [
		SettingsField(.soundEffectsEnabled, keyPath: \.soundEffectsEnabled, default: defaults.soundEffectsEnabled).eraseToAny(),
		SettingsField(.soundEffectsVolume, keyPath: \.soundEffectsVolume, default: defaults.soundEffectsVolume).eraseToAny(),
		SettingsField(.hotkey, keyPath: \.hotkey, default: defaults.hotkey).eraseToAny(),
		SettingsField(.openOnLogin, keyPath: \.openOnLogin, default: defaults.openOnLogin).eraseToAny(),
		SettingsField(.showDockIcon, keyPath: \.showDockIcon, default: defaults.showDockIcon).eraseToAny(),
		SettingsField(.indicatorSize, keyPath: \.indicatorSize, default: defaults.indicatorSize).eraseToAny(),
		SettingsField(.indicatorLocation, keyPath: \.indicatorLocation, default: defaults.indicatorLocation).eraseToAny(),
		SettingsField(.selectedModel, keyPath: \.selectedModel, default: defaults.selectedModel).eraseToAny(),
		SettingsField(.useClipboardPaste, keyPath: \.useClipboardPaste, default: defaults.useClipboardPaste).eraseToAny(),
		SettingsField(.preventSystemSleep, keyPath: \.preventSystemSleep, default: defaults.preventSystemSleep).eraseToAny(),
		SettingsField(
			.recordingAudioBehavior,
			keyPath: \.recordingAudioBehavior,
			default: defaults.recordingAudioBehavior,
			decode: { container, key, defaultValue in
				if let value = try container.decodeIfPresent(RecordingAudioBehavior.self, forKey: key) {
					return value
				}
				if let legacyPause = try container.decodeIfPresent(Bool.self, forKey: .pauseMediaOnRecord) {
					return legacyPause ? .pauseMedia : .doNothing
				}
				return defaultValue
			}
		).eraseToAny(),
		SettingsField(.minimumKeyTime, keyPath: \.minimumKeyTime, default: defaults.minimumKeyTime).eraseToAny(),
		SettingsField(.stopDelayMilliseconds, keyPath: \.stopDelayMilliseconds, default: defaults.stopDelayMilliseconds).eraseToAny(),
		SettingsField(
			.longRecordingConfirmationThresholdMinutes,
			keyPath: \.longRecordingConfirmationThresholdMinutes,
			default: defaults.longRecordingConfirmationThresholdMinutes
		).eraseToAny(),
		SettingsField(.copyToClipboard, keyPath: \.copyToClipboard, default: defaults.copyToClipboard).eraseToAny(),
		SettingsField(.superFastModeEnabled, keyPath: \.superFastModeEnabled, default: defaults.superFastModeEnabled).eraseToAny(),
		SettingsField(.useDoubleTapOnly, keyPath: \.useDoubleTapOnly, default: defaults.useDoubleTapOnly).eraseToAny(),
		SettingsField(.allowLongPressForOnDemand, keyPath: \.allowLongPressForOnDemand, default: defaults.allowLongPressForOnDemand).eraseToAny(),
		SettingsField(.doubleTapLockEnabled, keyPath: \.doubleTapLockEnabled, default: defaults.doubleTapLockEnabled).eraseToAny(),
		SettingsField(
			.outputLanguage,
			keyPath: \.outputLanguage,
			default: defaults.outputLanguage,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.selectedMicrophoneID,
			keyPath: \.selectedMicrophoneID,
			default: defaults.selectedMicrophoneID,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.saveTranscriptionHistory, keyPath: \.saveTranscriptionHistory, default: defaults.saveTranscriptionHistory).eraseToAny(),
		SettingsField(
			.maxHistoryEntries,
			keyPath: \.maxHistoryEntries,
			default: defaults.maxHistoryEntries,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(
			.pasteLastTranscriptHotkey,
			keyPath: \.pasteLastTranscriptHotkey,
			default: defaults.pasteLastTranscriptHotkey,
			encode: { container, key, value in
				try container.encodeIfPresent(value, forKey: key)
			}
		).eraseToAny(),
		SettingsField(.hasCompletedModelBootstrap, keyPath: \.hasCompletedModelBootstrap, default: defaults.hasCompletedModelBootstrap).eraseToAny(),
		SettingsField(.hasCompletedStorageMigration, keyPath: \.hasCompletedStorageMigration, default: defaults.hasCompletedStorageMigration).eraseToAny(),
		SettingsField(.wordRemovalsEnabled, keyPath: \.wordRemovalsEnabled, default: defaults.wordRemovalsEnabled).eraseToAny(),
		SettingsField(
			.wordRemovals,
			keyPath: \.wordRemovals,
			default: defaults.wordRemovals
		).eraseToAny(),
		SettingsField(
			.wordRemappings,
			keyPath: \.wordRemappings,
			default: defaults.wordRemappings
		).eraseToAny(),
		SettingsField(.lowercaseTranscripts, keyPath: \.lowercaseTranscripts, default: defaults.lowercaseTranscripts).eraseToAny(),
		SettingsField(.removePunctuation, keyPath: \.removePunctuation, default: defaults.removePunctuation).eraseToAny(),
		SettingsField(.speakerIdentificationEnabled, keyPath: \.speakerIdentificationEnabled, default: defaults.speakerIdentificationEnabled).eraseToAny(),
		SettingsField(.liveTranscriptionEnabled, keyPath: \.liveTranscriptionEnabled, default: defaults.liveTranscriptionEnabled).eraseToAny(),
		SettingsField(.speakerDiarizationMode, keyPath: \.speakerDiarizationMode, default: defaults.speakerDiarizationMode).eraseToAny(),
		SettingsField(.includeSystemAudio, keyPath: \.includeSystemAudio, default: defaults.includeSystemAudio).eraseToAny(),
		SettingsField(.speakerDiarizationProvider, keyPath: \.speakerDiarizationProvider, default: defaults.speakerDiarizationProvider).eraseToAny(),
		SettingsField(.refinementMode, keyPath: \.refinementMode, default: defaults.refinementMode).eraseToAny(),
		SettingsField(.refinementEnabled, keyPath: \.refinementEnabled, default: defaults.refinementEnabled).eraseToAny(),
		SettingsField(.refinementProvider, keyPath: \.refinementProvider, default: defaults.refinementProvider).eraseToAny(),
		SettingsField(.refinementReasoningEffort, keyPath: \.refinementReasoningEffort, default: defaults.refinementReasoningEffort).eraseToAny(),
		SettingsField(.agentHandoffProvider, keyPath: \.agentHandoffProvider, default: defaults.agentHandoffProvider).eraseToAny(),
		SettingsField(.agentHandoffEnabled, keyPath: \.agentHandoffEnabled, default: defaults.agentHandoffEnabled).eraseToAny(),
		SettingsField(
			.agentHandoffModelID,
			keyPath: \.agentHandoffModelID,
			default: defaults.agentHandoffModelID,
			encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
		).eraseToAny(),
		SettingsField(
			.agentHandoffReasoningEffort,
			keyPath: \.agentHandoffReasoningEffort,
			default: defaults.agentHandoffReasoningEffort
		).eraseToAny(),
		SettingsField(
			.hasCompletedRefinementProviderDetection,
			keyPath: \.hasCompletedRefinementProviderDetection,
			default: defaults.hasCompletedRefinementProviderDetection
		).eraseToAny(),
		SettingsField(
			.openAIModelID,
			keyPath: \.openAIModelID,
			default: defaults.openAIModelID,
			encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
		).eraseToAny(),
		SettingsField(
			.anthropicModelID,
			keyPath: \.anthropicModelID,
			default: defaults.anthropicModelID,
			encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
		).eraseToAny(),
		SettingsField(
			.codexCLIModelID,
			keyPath: \.codexCLIModelID,
			default: defaults.codexCLIModelID,
			encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
		).eraseToAny(),
		SettingsField(
			.claudeCLIModelID,
			keyPath: \.claudeCLIModelID,
			default: defaults.claudeCLIModelID,
			encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
		).eraseToAny(),
		SettingsField(.refinementInstructions, keyPath: \.refinementInstructions, default: defaults.refinementInstructions).eraseToAny(),
		SettingsField(.rewritePrompts, keyPath: \.rewritePrompts, default: defaults.rewritePrompts).eraseToAny(),
			SettingsField(
				.openRouterModelID,
				keyPath: \.openRouterModelID,
				default: defaults.openRouterModelID,
				encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
			).eraseToAny(),
		SettingsField(
			.openRouterShortlistedModelIDs,
			keyPath: \.openRouterShortlistedModelIDs,
			default: defaults.openRouterShortlistedModelIDs
		).eraseToAny(),
		SettingsField(
			.screenAwareOpenRouterModelID,
			keyPath: \.screenAwareOpenRouterModelID,
			default: defaults.screenAwareOpenRouterModelID,
			encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
		).eraseToAny(),
		SettingsField(.screenAwareDictationEnabled, keyPath: \.screenAwareDictationEnabled, default: defaults.screenAwareDictationEnabled).eraseToAny(),
		SettingsField(.screenAwareInputSource, keyPath: \.screenAwareInputSource, default: defaults.screenAwareInputSource).eraseToAny(),
		SettingsField(.includeSelectedTextInRefinement, keyPath: \.includeSelectedTextInRefinement, default: defaults.includeSelectedTextInRefinement).eraseToAny()
	]
}
