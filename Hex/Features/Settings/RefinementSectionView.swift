import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Settings for the optional, downstream transcript-refinement stage.
struct RefinementSectionView: View {
	@ObserveInjection var inject
	@Bindable var store: StoreOf<SettingsFeature>
	@State private var geminiAPIKey = ""
	@State private var openRouterAPIKey = ""
	@State private var openAIAPIKey = ""
	@State private var anthropicAPIKey = ""
	@State private var isShowingOpenRouterModelPicker = false
	@State private var isShowingScreenAwareModelPicker = false
	@State private var directModelPickerTarget: DirectModelPickerTarget?

	private enum DirectModelPickerTarget: Identifiable {
		case refinement
		case screenAware

		var id: Self { self }
	}

	var body: some View {
		Section {
			let refinedHotkey = store.hexSettings.refinedHotkey ?? .init(key: nil, modifiers: [])
			let refinedKey = store.isSettingRefinedHotKey ? nil : refinedHotkey.key
			let refinedModifiers = store.isSettingRefinedHotKey ? store.currentRefinedModifiers : refinedHotkey.modifiers

			VStack(alignment: .leading, spacing: 14) {
				RefinedHotKeyIntroduction(
					hasConflict: store.hexSettings.refinedHotkey?.conflicts(with: store.hexSettings.hotkey) ?? false
				)

				HStack {
					Spacer()
					HotKeyView(modifiers: refinedModifiers, key: refinedKey, isActive: store.isSettingRefinedHotKey)
					Spacer()
				}
				.contentShape(Rectangle())
				.onTapGesture { store.send(.startSettingRefinedHotKey) }
			}
			.listRowSeparator(.hidden)

			if !store.isSettingRefinedHotKey, refinedHotkey.key == nil, !refinedHotkey.modifiers.isEmpty {
				ModifierSideControls(modifiers: refinedHotkey.modifiers) { kind, side in
					store.send(.setRefinedModifierSide(kind, side))
				}
				.listRowSeparator(.hidden, edges: .top)
			}

			Label {
				Toggle("Enable double-tap lock", isOn: $store.hexSettings.refinedDoubleTapLockEnabled)
			} icon: {
				Image(systemName: "hand.tap")
			}

			if store.hexSettings.refinedDoubleTapLockEnabled {
				Label {
					Toggle("Use double-tap only", isOn: $store.hexSettings.refinedUseDoubleTapOnly)
				} icon: {
					Image(systemName: "hand.tap.fill")
				}
			}

			if refinedHotkey.key == nil, !(store.hexSettings.refinedDoubleTapLockEnabled && store.hexSettings.refinedUseDoubleTapOnly) {
				Label {
					Slider(value: $store.hexSettings.refinedMinimumKeyTime, in: 0 ... 2, step: 0.1) {
						Text("Ignore below \(store.hexSettings.refinedMinimumKeyTime, specifier: "%.1f")s")
					}
				} icon: {
					Image(systemName: "clock")
				}
			}

			Label {
				Toggle("Include selected text", isOn: $store.hexSettings.includeSelectedTextInRefinement)
			} icon: {
				Image(systemName: "text.cursor")
			}

			Label {
				Picker("Provider", selection: $store.hexSettings.refinementProvider) {
					Text("Apple Intelligence").tag(RefinementProvider.apple)
					Text("Gemini Flash").tag(RefinementProvider.gemini)
					Text("OpenRouter").tag(RefinementProvider.openRouter)
					Text("OpenAI / Codex").tag(RefinementProvider.openAI)
					Text("Claude (Anthropic)").tag(RefinementProvider.anthropic)
				}
			} icon: {
				Image(systemName: "cpu")
			}

				if store.hexSettings.refinementProvider == .apple {
					if #unavailable(macOS 26.0) {
						Text("Apple Intelligence refinement requires macOS 26 or later. Until then, Hex keeps the processed transcript unchanged.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				if store.hexSettings.refinementProvider == .openAI {
					VStack(alignment: .leading, spacing: 8) {
						SecureField("OpenAI API Key", text: $openAIAPIKey)
							.onSubmit(persistOpenAIAPIKey)
						Button {
							persistOpenAIAPIKey()
							directModelPickerTarget = .refinement
						} label: {
							LabeledContent("Default Model") {
								Text(store.hexSettings.openRouterModelID ?? "Select a model")
									.foregroundStyle(store.hexSettings.openRouterModelID == nil ? .secondary : .primary)
							}
						}
						.disabled(openAIAPIKey.isEmpty)
						Text("Your key is stored securely in Keychain. Hex refreshes the models available to this key when you open the picker. OpenAI receives the completed transcript, or a screen image when enabled; audio is never sent.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.listRowSeparator(.hidden)
				}

				if store.hexSettings.refinementProvider == .anthropic {
					VStack(alignment: .leading, spacing: 8) {
						SecureField("Claude API Key", text: $anthropicAPIKey)
							.onSubmit(persistAnthropicAPIKey)
						Button {
							persistAnthropicAPIKey()
							directModelPickerTarget = .refinement
						} label: {
							LabeledContent("Default Model") {
								Text(store.hexSettings.openRouterModelID ?? "Select a model")
									.foregroundStyle(store.hexSettings.openRouterModelID == nil ? .secondary : .primary)
							}
						}
						.disabled(anthropicAPIKey.isEmpty)
						Text("Your key is stored securely in Keychain. Hex refreshes the models available to this key when you open the picker. Anthropic receives the completed transcript, or a screen image when enabled; audio is never sent.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.listRowSeparator(.hidden)
				}

				if store.hexSettings.refinementProvider == .gemini {
					SecureField("Gemini API Key", text: $geminiAPIKey)
						.onSubmit(persistGeminiAPIKey)
					Text("Stored securely in Keychain. Without a key, Hex pastes the processed transcript unchanged.")
						.font(.caption)
						.foregroundStyle(.secondary)
					Text("Gemini sends the completed, locally transformed transcript text to Google. Audio is never sent.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				if store.hexSettings.refinementProvider == .openRouter {
					VStack(alignment: .leading, spacing: 8) {
						SecureField("OpenRouter API Key", text: $openRouterAPIKey)
							.onSubmit(persistOpenRouterAPIKey)
						Button {
							persistOpenRouterAPIKey()
							isShowingOpenRouterModelPicker = true
						} label: {
							LabeledContent("Default Model") {
								Text(store.hexSettings.openRouterModelID ?? "Select a model")
									.foregroundStyle(store.hexSettings.openRouterModelID == nil ? .secondary : .primary)
							}
						}
						.disabled(openRouterAPIKey.isEmpty)
						Text("Your key is stored securely in Keychain. Choose any text model from the cached OpenRouter catalog. OpenRouter sends the completed, locally transformed transcript text to the selected model; audio is never sent.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.listRowSeparator(.hidden)
				}

			VStack(alignment: .leading, spacing: 8) {
				Label("Refinement Instructions", systemImage: "sparkles")
					.font(.headline)
				TextEditor(text: $store.hexSettings.refinementInstructions)
					.font(.body)
					.multilineTextAlignment(.leading)
					.frame(maxWidth: .infinity, minHeight: 130, maxHeight: 180, alignment: .topLeading)
					.padding(8)
					.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
			}
			.frame(maxWidth: .infinity, alignment: .leading)

					VStack(alignment: .leading, spacing: 8) {
						HStack {
							Label("Screen-aware Dictation", systemImage: "rectangle.and.text.magnifyingglass")
								.font(.headline)
							Spacer()
							Toggle("Enable Screen-aware Dictation", isOn: screenAwareDictationEnabled)
								.labelsHidden()
								.disabled(store.isRequestingScreenRecordingPermission)
						}
						if store.needsScreenRecordingPermission {
							Text("Screen Recording permission is required. Enable Hex in Privacy & Security → Screen Recording, then try again.")
								.font(.caption)
								.foregroundStyle(.secondary)
							Button("Open Screen Recording Settings") {
								store.send(.openScreenRecordingSettings)
							}
						}
						if store.hexSettings.screenAwareDictationEnabled {
							Text("Long-press the refinement hotkey to capture the display under the cursor as Screen-aware mode activates. With double-tap lock enabled, release the second tap for regular refinement or keep holding it for Screen-aware mode.")
								.font(.caption)
								.foregroundStyle(.secondary)
							Picker("Analysis source", selection: $store.hexSettings.screenAwareInputSource) {
								Text("Local Apple Vision OCR").tag(ScreenAwareInputSource.localOCR)
								Text("Upload screenshot").tag(ScreenAwareInputSource.image)
							}
							.pickerStyle(.radioGroup)
							Text(screenAwareSourceDescription)
								.font(.caption)
								.foregroundStyle(.secondary)
							if store.hexSettings.screenAwareInputSource.uploadsScreenshot {
							if selectedImageProvider == .openRouter, store.hexSettings.refinementProvider != .openRouter {
								SecureField("OpenRouter API Key", text: $openRouterAPIKey)
									.onSubmit(persistOpenRouterAPIKey)
							}
							Button {
								if selectedImageProvider == .openRouter {
									persistOpenRouterAPIKey()
									isShowingScreenAwareModelPicker = true
								} else {
									persistSelectedDirectAPIKey()
									directModelPickerTarget = .screenAware
								}
							} label: {
								LabeledContent(selectedImageProvider == .openRouter ? "Fallback Image Model" : "Screen-aware Model") {
										Text(store.hexSettings.screenAwareOpenRouterModelID ?? "Select a model")
											.foregroundStyle(store.hexSettings.screenAwareOpenRouterModelID == nil ? .secondary : .primary)
									}
								}
							.disabled(selectedImageAPIKey.isEmpty)
							Text(selectedImageProvider == .openRouter ? "Used only when the selected refinement model cannot accept image input." : "Choose a model that supports image input for screen-aware dictation.")
									.font(.caption)
									.foregroundStyle(.secondary)
							if selectedImageAPIKey.isEmpty {
								Text("Uploading a screenshot requires a \(selectedImageProviderName) API key. Local Apple Vision OCR does not upload the image.")
										.font(.caption)
										.foregroundStyle(.secondary)
								}
							}
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
		} header: {
			VStack(alignment: .leading, spacing: 4) {
				Text("Transcription Refinement")
				Text("Rewrite or clean up your transcriptions and/or selected text with custom prompts")
					.lineLimit(1)
					.truncationMode(.tail)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.task {
			geminiAPIKey = GeminiAPIKeyStore.read() ?? ""
			openRouterAPIKey = OpenRouterAPIKeyStore.read() ?? ""
			openAIAPIKey = OpenAIAPIKeyStore.read() ?? ""
			anthropicAPIKey = AnthropicAPIKeyStore.read() ?? ""
		}
		.onChange(of: store.hexSettings.refinementProvider) { oldProvider, _ in
			if oldProvider == .gemini { persistGeminiAPIKey() }
			if oldProvider == .openRouter { persistOpenRouterAPIKey() }
			if oldProvider == .openAI { persistOpenAIAPIKey() }
			if oldProvider == .anthropic { persistAnthropicAPIKey() }
		}
		.onChange(of: openRouterAPIKey) { _, key in
			// Clearing the field explicitly opts out of the saved Keychain credential.
			if key.isEmpty { persistOpenRouterAPIKey() }
		}
		.onChange(of: openAIAPIKey) { _, key in
			if key.isEmpty { persistOpenAIAPIKey() }
		}
		.onChange(of: anthropicAPIKey) { _, key in
			if key.isEmpty { persistAnthropicAPIKey() }
		}
		.onDisappear {
			persistGeminiAPIKey()
			persistOpenRouterAPIKey()
			persistOpenAIAPIKey()
			persistAnthropicAPIKey()
		}
			.sheet(isPresented: $isShowingOpenRouterModelPicker) {
				OpenRouterModelPickerView(
					selectedModelID: $store.hexSettings.openRouterModelID,
					apiKey: openRouterAPIKey,
					requiredInputModality: .text
				)
			}
			.sheet(isPresented: $isShowingScreenAwareModelPicker) {
				OpenRouterModelPickerView(
					selectedModelID: $store.hexSettings.screenAwareOpenRouterModelID,
					apiKey: openRouterAPIKey,
					requiredInputModality: .image
				)
			}
			.sheet(item: $directModelPickerTarget) { target in
				DirectProviderModelPickerView(
					selectedModelID: modelBinding(for: target),
					provider: store.hexSettings.refinementProvider,
					apiKey: selectedImageProvider == .openAI ? openAIAPIKey : anthropicAPIKey,
					requiredInputModality: target == .screenAware ? .image : .text
				)
			}
		.enableInjection()
	}

	private func persistGeminiAPIKey() {
		persistAPIKey(geminiAPIKey, providerName: "Gemini", save: GeminiAPIKeyStore.save, delete: GeminiAPIKeyStore.delete)
	}

	private func persistOpenRouterAPIKey() {
		persistAPIKey(openRouterAPIKey, providerName: "OpenRouter", save: OpenRouterAPIKeyStore.save, delete: OpenRouterAPIKeyStore.delete)
	}

	private func persistOpenAIAPIKey() {
		persistAPIKey(openAIAPIKey, providerName: "OpenAI", save: OpenAIAPIKeyStore.save, delete: OpenAIAPIKeyStore.delete)
	}

	private func persistAnthropicAPIKey() {
		persistAPIKey(anthropicAPIKey, providerName: "Anthropic", save: AnthropicAPIKeyStore.save, delete: AnthropicAPIKeyStore.delete)
	}

	private func persistSelectedDirectAPIKey() {
		if selectedImageProvider == .openAI { persistOpenAIAPIKey() }
		if selectedImageProvider == .anthropic { persistAnthropicAPIKey() }
	}

	private func modelBinding(for target: DirectModelPickerTarget) -> Binding<String?> {
		switch target {
		case .refinement: $store.hexSettings.openRouterModelID
		case .screenAware: $store.hexSettings.screenAwareOpenRouterModelID
		}
	}

	private var selectedImageProvider: RefinementProvider {
		switch store.hexSettings.refinementProvider {
		case .openAI, .anthropic, .openRouter: store.hexSettings.refinementProvider
		case .apple, .gemini: .openRouter
		}
	}

	private var selectedImageAPIKey: String {
		switch selectedImageProvider {
		case .openAI: openAIAPIKey
		case .anthropic: anthropicAPIKey
		case .openRouter, .apple, .gemini: openRouterAPIKey
		}
	}

	private var selectedImageProviderName: String {
		switch selectedImageProvider {
		case .openAI: "OpenAI"
		case .anthropic: "Anthropic"
		case .openRouter: "OpenRouter"
		case .apple: "Apple Intelligence"
		case .gemini: "Gemini"
		}
	}

	private var screenAwareSourceDescription: String {
		switch store.hexSettings.screenAwareInputSource {
		case .localOCR:
			"Fastest and most private: Apple Vision extracts text on your Mac, then Hex uses your selected refinement model with that text and your spoken request. Best for documents, email, and other text-based screens."
		case .image:
			"Best for layout, charts, icons, imagery, or other visual details: Hex sends a compressed analysis copy of the screenshot to the selected image-capable provider."
		}
	}

	private func persistAPIKey(
		_ key: String,
		providerName: String,
		save: (String) throws -> Void,
		delete: () throws -> Void
	) {
		do {
			if key.isEmpty {
				try delete()
			} else {
				try save(key)
			}
		} catch {
			HexLog.settings.error("Could not save \(providerName, privacy: .public) API key: \(error.localizedDescription, privacy: .private)")
		}
	}

	private var screenAwareDictationEnabled: Binding<Bool> {
		Binding(
			get: { store.hexSettings.screenAwareDictationEnabled },
			set: { store.send(.setScreenAwareDictationEnabled($0)) }
		)
	}
}

private struct RefinedHotKeyIntroduction: View {
	let hasConflict: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Label("Refined Transcription Hotkey", systemImage: "keyboard")
				.font(.headline)
			Text("Records normally, then always runs refinement using the instructions above.")
				.font(.caption)
				.foregroundStyle(.secondary)
			if hasConflict {
				Text("Choose a non-overlapping shortcut. A modifier-only shortcut cannot share a prefix with the regular shortcut.")
					.font(.caption)
					.foregroundStyle(.orange)
			}
		}
	}
}
