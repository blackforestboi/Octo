import Foundation

public enum RecordingAudioBehavior: String, Codable, CaseIterable, Equatable, Sendable {
	case pauseMedia
	case mute
	case doNothing
}

/// User-configurable settings saved to disk.
public struct HexSettings: Codable, Equatable, Sendable {
	public static let defaultPasteLastTranscriptHotkey = HotKey(key: .v, modifiers: [.option, .shift])
	public static let baseSoundEffectsVolume: Double = HexCoreConstants.baseSoundEffectsVolume
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
	public var selectedModel: String
	public var useClipboardPaste: Bool
	public var preventSystemSleep: Bool
	public var recordingAudioBehavior: RecordingAudioBehavior
	public var minimumKeyTime: Double
	public var stopDelayMilliseconds: Int
	public var copyToClipboard: Bool
	public var superFastModeEnabled: Bool
	public var useDoubleTapOnly: Bool
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
	/// Optional post-processing is deliberately separate from the transcription pipeline.
	public var refinementMode: RefinementMode
	public var refinementProvider: RefinementProvider
	/// User-authored instructions appended to Hex's refinement contract.
	public var refinementInstructions: String
	public var openRouterModelID: String?
	/// Vision-capable OpenRouter model used only when the selected refinement model
	/// cannot accept an uploaded screenshot.
	public var screenAwareOpenRouterModelID: String?
	/// Keeps the selected Screen Aware model while allowing the feature to be disabled.
	public var screenAwareDictationEnabled: Bool
	/// Chooses whether Screen Aware sends a screenshot to OpenRouter or uses local OCR only.
	public var screenAwareInputSource: ScreenAwareInputSource
	/// Optional second recording shortcut that always runs the refinement stage.
	public var refinedHotkey: HotKey?
	public var refinedDoubleTapLockEnabled: Bool
	public var refinedUseDoubleTapOnly: Bool
	public var refinedMinimumKeyTime: Double
	/// Whether the refined-transcription hotkey captures selected text as the source material.
	public var includeSelectedTextInRefinement: Bool

	public var isScreenAwareDictationConfigured: Bool {
		screenAwareDictationEnabled
	}

	public var hasScreenAwareImageFallbackModel: Bool {
		guard let screenAwareOpenRouterModelID else { return false }
		return !screenAwareOpenRouterModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	public func refinementRequest(
		for text: String,
		mode: RefinementMode,
		spokenInstruction: String? = nil
	) -> RefinementRequest {
		let spokenInstruction = spokenInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		var instructionParts = [refinementInstructions.trimmingCharacters(in: .whitespacesAndNewlines)]
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
			modelID: openRouterModelID
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
				instructions: refinementInstructions.trimmingCharacters(in: .whitespacesAndNewlines),
			provider: usesUploadedImage && !refinementProvider.supportsImageInput ? .openRouter : refinementProvider,
				modelID: usesUploadedImage ? (imageModelID ?? screenAwareOpenRouterModelID) : openRouterModelID,
				screenContext: context,
				screenAwareInputSource: inputSource
			)
		}

	private mutating func normalizeDoubleTapSettings() {
		if !doubleTapLockEnabled {
			useDoubleTapOnly = false
		}
		if !refinedDoubleTapLockEnabled {
			refinedUseDoubleTapOnly = false
		}
	}

	public init(
		soundEffectsEnabled: Bool = true,
		soundEffectsVolume: Double = HexSettings.baseSoundEffectsVolume,
		hotkey: HotKey = .init(key: nil, modifiers: [.option]),
		openOnLogin: Bool = false,
		showDockIcon: Bool = true,
		selectedModel: String = ParakeetModel.multilingualV3.identifier,
		useClipboardPaste: Bool = true,
		preventSystemSleep: Bool = true,
		recordingAudioBehavior: RecordingAudioBehavior = .doNothing,
		minimumKeyTime: Double = HexCoreConstants.defaultMinimumKeyTime,
		stopDelayMilliseconds: Int = 0,
		copyToClipboard: Bool = false,
		superFastModeEnabled: Bool = true,
		useDoubleTapOnly: Bool = false,
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
		refinementMode: RefinementMode = .raw,
		refinementProvider: RefinementProvider = .apple,
			refinementInstructions: String = HexSettings.defaultRefinementInstructions,
			openRouterModelID: String? = nil,
			screenAwareOpenRouterModelID: String? = nil,
			screenAwareDictationEnabled: Bool = false,
			screenAwareInputSource: ScreenAwareInputSource = .localOCR,
			refinedHotkey: HotKey? = .init(key: nil, modifiers: [.option]),
		refinedDoubleTapLockEnabled: Bool = true,
		refinedUseDoubleTapOnly: Bool = false,
		refinedMinimumKeyTime: Double = HexCoreConstants.defaultMinimumKeyTime,
		includeSelectedTextInRefinement: Bool = true
	) {
		self.soundEffectsEnabled = soundEffectsEnabled
		self.soundEffectsVolume = soundEffectsVolume
		self.hotkey = hotkey
		self.openOnLogin = openOnLogin
		self.showDockIcon = showDockIcon
		self.selectedModel = selectedModel
		self.useClipboardPaste = useClipboardPaste
		self.preventSystemSleep = preventSystemSleep
		self.recordingAudioBehavior = recordingAudioBehavior
		self.minimumKeyTime = minimumKeyTime
		self.stopDelayMilliseconds = max(0, stopDelayMilliseconds)
		self.copyToClipboard = copyToClipboard
		self.superFastModeEnabled = superFastModeEnabled
		self.useDoubleTapOnly = useDoubleTapOnly
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
		self.refinementMode = refinementMode
		self.refinementProvider = refinementProvider
			self.refinementInstructions = refinementInstructions
			self.openRouterModelID = openRouterModelID
			self.screenAwareOpenRouterModelID = screenAwareOpenRouterModelID
			self.screenAwareDictationEnabled = screenAwareDictationEnabled
			self.screenAwareInputSource = screenAwareInputSource
		self.refinedHotkey = refinedHotkey
		self.refinedDoubleTapLockEnabled = refinedDoubleTapLockEnabled
		self.refinedUseDoubleTapOnly = refinedUseDoubleTapOnly
		self.refinedMinimumKeyTime = refinedMinimumKeyTime
		self.includeSelectedTextInRefinement = includeSelectedTextInRefinement
		normalizeDoubleTapSettings()
	}

	public init(from decoder: Decoder) throws {
		self.init()
		let container = try decoder.container(keyedBy: HexSettingKey.self)
		for field in HexSettingsSchema.fields {
			try field.decode(into: &self, from: container)
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
		case .apple, .gemini:
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
	case selectedModel
	case useClipboardPaste
	case preventSystemSleep
	case recordingAudioBehavior
	case pauseMediaOnRecord // Legacy
	case minimumKeyTime
	case stopDelayMilliseconds
	case copyToClipboard
	case superFastModeEnabled
	case useDoubleTapOnly
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
	case refinementMode
	case refinementProvider
		case refinementInstructions
		case openRouterModelID
		case screenAwareOpenRouterModelID
		case screenAwareDictationEnabled
		case screenAwareInputSource
		case refinedHotkey
	case refinedDoubleTapLockEnabled
	case refinedUseDoubleTapOnly
	case refinedMinimumKeyTime
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
		SettingsField(.copyToClipboard, keyPath: \.copyToClipboard, default: defaults.copyToClipboard).eraseToAny(),
		SettingsField(.superFastModeEnabled, keyPath: \.superFastModeEnabled, default: defaults.superFastModeEnabled).eraseToAny(),
		SettingsField(.useDoubleTapOnly, keyPath: \.useDoubleTapOnly, default: defaults.useDoubleTapOnly).eraseToAny(),
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
		SettingsField(.refinementMode, keyPath: \.refinementMode, default: defaults.refinementMode).eraseToAny(),
		SettingsField(.refinementProvider, keyPath: \.refinementProvider, default: defaults.refinementProvider).eraseToAny(),
		SettingsField(.refinementInstructions, keyPath: \.refinementInstructions, default: defaults.refinementInstructions).eraseToAny(),
			SettingsField(
				.openRouterModelID,
				keyPath: \.openRouterModelID,
				default: defaults.openRouterModelID,
				encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
			).eraseToAny(),
		SettingsField(
			.screenAwareOpenRouterModelID,
			keyPath: \.screenAwareOpenRouterModelID,
			default: defaults.screenAwareOpenRouterModelID,
			encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
		).eraseToAny(),
		SettingsField(.screenAwareDictationEnabled, keyPath: \.screenAwareDictationEnabled, default: defaults.screenAwareDictationEnabled).eraseToAny(),
		SettingsField(.screenAwareInputSource, keyPath: \.screenAwareInputSource, default: defaults.screenAwareInputSource).eraseToAny(),
		SettingsField(
			.refinedHotkey,
			keyPath: \.refinedHotkey,
			default: defaults.refinedHotkey,
			encode: { container, key, value in try container.encodeIfPresent(value, forKey: key) }
		).eraseToAny(),
		SettingsField(.refinedDoubleTapLockEnabled, keyPath: \.refinedDoubleTapLockEnabled, default: defaults.refinedDoubleTapLockEnabled).eraseToAny(),
		SettingsField(.refinedUseDoubleTapOnly, keyPath: \.refinedUseDoubleTapOnly, default: defaults.refinedUseDoubleTapOnly).eraseToAny(),
		SettingsField(.refinedMinimumKeyTime, keyPath: \.refinedMinimumKeyTime, default: defaults.refinedMinimumKeyTime).eraseToAny(),
		SettingsField(.includeSelectedTextInRefinement, keyPath: \.includeSelectedTextInRefinement, default: defaults.includeSelectedTextInRefinement).eraseToAny()
	]
}
