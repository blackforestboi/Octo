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
	@State private var subscriptionModelPickerTarget: SubscriptionModelPickerTarget?

	private enum DirectModelPickerTarget: Identifiable {
		case refinement
		case screenAware

		var id: Self { self }
	}

	private enum SubscriptionModelPickerTarget: Identifiable {
		case codex
		case claude

		var id: Self { self }

		var provider: CLIRefinementClient.Provider {
			switch self {
			case .codex: .codex
			case .claude: .claude
			}
		}
	}

	var body: some View {
		Section {
			Label {
				Toggle("Include selected text", isOn: $store.hexSettings.includeSelectedTextInRefinement)
			} icon: {
				Image(systemName: "text.cursor")
			}

			Label {
				Picker("Provider", selection: $store.hexSettings.refinementProvider) {
					Text("Apple Intelligence").tag(RefinementProvider.apple)
					Text("Gemini Flash API").tag(RefinementProvider.gemini)
					Text("OpenRouter API").tag(RefinementProvider.openRouter)
					Text("OpenAI API").tag(RefinementProvider.openAI)
					Text("Claude API").tag(RefinementProvider.anthropic)
					Text("OpenAI Subscription").tag(RefinementProvider.codexCLI)
					Text("Claude Subscription").tag(RefinementProvider.claudeCLI)
				}
			} icon: {
				Image(systemName: "cpu")
			}

			Label {
				Picker("Reasoning", selection: $store.hexSettings.refinementReasoningEffort) {
					ForEach(RefinementReasoningEffort.allCases, id: \.self) { effort in
						Text(effort.displayName).tag(effort)
					}
				}
			} icon: {
				Image(systemName: "brain")
			}
			Text("Sets the requested thinking level for refinement. Availability varies by provider and selected model.")
				.font(.caption)
				.foregroundStyle(.secondary)

				if store.hexSettings.refinementProvider == .apple {
					LabeledContent("Model") {
						Text("Apple Intelligence default")
					}
					Text("Uses Apple Intelligence on your Mac; audio is never sent.")
						.font(.caption)
						.foregroundStyle(.secondary)
					if #unavailable(macOS 26.0) {
						Text("Apple Intelligence refinement requires macOS 26 or later. Until then, Octo keeps the processed transcript unchanged.")
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
							LabeledContent("Model") {
								Text(store.hexSettings.openAIModelID ?? store.hexSettings.openRouterModelID ?? "Select a model")
									.foregroundStyle(store.hexSettings.openAIModelID == nil && store.hexSettings.openRouterModelID == nil ? .secondary : .primary)
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.contentShape(Rectangle())
						.disabled(openAIAPIKey.isEmpty)
						Text("Uses your OpenAI API key. Octo sends the completed refinement prompt, or a screen image when enabled; audio is never sent.")
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
							LabeledContent("Model") {
								Text(store.hexSettings.anthropicModelID ?? store.hexSettings.openRouterModelID ?? "Select a model")
									.foregroundStyle(store.hexSettings.anthropicModelID == nil && store.hexSettings.openRouterModelID == nil ? .secondary : .primary)
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.contentShape(Rectangle())
						.disabled(anthropicAPIKey.isEmpty)
						Text("Uses your Claude API key. Octo sends the completed refinement prompt, or a screen image when enabled; audio is never sent.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.listRowSeparator(.hidden)
				}

				if store.hexSettings.refinementProvider == .gemini {
					SecureField("Gemini API Key", text: $geminiAPIKey)
						.onSubmit(persistGeminiAPIKey)
					LabeledContent("Model") {
						Text("Gemini 3.1 Flash Lite")
					}
					Text("Uses your Gemini API key. Octo sends the completed refinement prompt to Google; audio is never sent.")
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
								LabeledContent("Model") {
									Text(store.hexSettings.openRouterModelID ?? "Select a model")
										.foregroundStyle(store.hexSettings.openRouterModelID == nil ? .secondary : .primary)
								}
							}
						.frame(maxWidth: .infinity, alignment: .leading)
						.contentShape(Rectangle())
						.disabled(openRouterAPIKey.isEmpty)
						Text("Uses your OpenRouter API key. Octo sends the completed refinement prompt to the selected model; audio is never sent.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.listRowSeparator(.hidden)
				}

				if store.hexSettings.refinementProvider == .codexCLI {
					VStack(alignment: .leading, spacing: 8) {
						Button {
							subscriptionModelPickerTarget = .codex
						} label: {
							LabeledContent("Model") {
								Text(store.hexSettings.codexCLIModelID ?? "Codex default")
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.contentShape(Rectangle())
						Text("Uses your signed-in OpenAI subscription through the local Codex CLI. Octo sends only the completed refinement prompt; audio is never sent.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				if store.hexSettings.refinementProvider == .claudeCLI {
					VStack(alignment: .leading, spacing: 8) {
						Button {
							subscriptionModelPickerTarget = .claude
						} label: {
							LabeledContent("Model") {
								Text(store.hexSettings.claudeCLIModelID ?? "Claude default")
							}
						}
						.frame(maxWidth: .infinity, alignment: .leading)
						.contentShape(Rectangle())
						Text("Uses your signed-in Claude subscription through the local Claude Code CLI. Octo sends only the completed refinement prompt; audio is never sent.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
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
							Text("Screen Recording permission is required. Enable Octo in Privacy & Security → Screen Recording, then try again.")
								.font(.caption)
								.foregroundStyle(.secondary)
							Button("Open Screen Recording Settings") {
								store.send(.openScreenRecordingSettings)
							}
						}
						if store.hexSettings.screenAwareDictationEnabled {
								Text("Quick-tap the recording hotkey once, then hold the second press to capture the display under the cursor. Screen-aware recordings always use refinement.")
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
							if !selectedImageAPIKey.isEmpty {
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
							}
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
					.font(.footnote)
					.foregroundColor(.secondary)
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
			store.send(.refinementProviderChanged(store.hexSettings.refinementProvider))
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
			.sheet(item: $subscriptionModelPickerTarget) { target in
				SubscriptionModelPickerView(
					selectedModelID: subscriptionModelBinding(for: target),
					provider: target.provider
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
		case .refinement:
			switch store.hexSettings.refinementProvider {
			case .openAI: $store.hexSettings.openAIModelID
			case .anthropic: $store.hexSettings.anthropicModelID
			case .apple, .gemini, .openRouter, .codexCLI, .claudeCLI: $store.hexSettings.openRouterModelID
			}
		case .screenAware: $store.hexSettings.screenAwareOpenRouterModelID
		}
	}

	private func subscriptionModelBinding(for target: SubscriptionModelPickerTarget) -> Binding<String?> {
		switch target {
		case .codex: $store.hexSettings.codexCLIModelID
		case .claude: $store.hexSettings.claudeCLIModelID
		}
	}

	private var selectedImageProvider: RefinementProvider {
		switch store.hexSettings.refinementProvider {
		case .openAI, .anthropic, .openRouter: store.hexSettings.refinementProvider
		case .apple, .gemini, .codexCLI, .claudeCLI: .openRouter
		}
	}

	private var selectedImageAPIKey: String {
		switch selectedImageProvider {
		case .openAI: openAIAPIKey
		case .anthropic: anthropicAPIKey
		case .openRouter, .apple, .gemini, .codexCLI, .claudeCLI: openRouterAPIKey
		}
	}

	private var selectedImageProviderName: String {
		switch selectedImageProvider {
		case .openAI: "OpenAI"
		case .anthropic: "Anthropic"
		case .openRouter: "OpenRouter"
		case .apple: "Apple Intelligence"
		case .gemini: "Gemini"
		case .codexCLI, .claudeCLI: "OpenRouter"
		}
	}

	private var screenAwareSourceDescription: String {
		switch store.hexSettings.screenAwareInputSource {
		case .localOCR:
			"Fastest and most private: Apple Vision extracts text on your Mac, then Octo uses your selected refinement model with that text and your spoken request. Best for documents, email, and other text-based screens."
		case .image:
			"Best for layout, charts, icons, imagery, or other visual details: Octo sends a compressed analysis copy of the screenshot to the selected image-capable provider."
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
