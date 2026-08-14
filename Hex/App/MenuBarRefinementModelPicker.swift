import ComposableArchitecture
import HexCore
import SwiftUI

struct RefinementModelMenuOption: Equatable, Identifiable, Sendable {
	let provider: RefinementProvider
	let modelID: String?
	let name: String
	let isEnabled: Bool

	var id: String {
		"\(provider.rawValue):\(modelID ?? "__default__")"
	}

	func disabled() -> Self {
		.init(provider: provider, modelID: modelID, name: name, isEnabled: false)
	}
}

enum RefinementModelMenuStatus: Equatable {
	case loading
	case message(String)

	var text: String {
		switch self {
		case .loading:
			"Loading models…"
		case let .message(message):
			message
		}
	}
}

struct RefinementModelMenuState: Equatable {
	var provider: RefinementProvider
	var options: [RefinementModelMenuOption] = []
	var status: RefinementModelMenuStatus?

	mutating func beginLoading(
		provider: RefinementProvider,
		cachedOptions: [RefinementModelMenuOption]
	) {
		self.provider = provider
		options = Self.sorted(cachedOptions)
		status = .loading
	}

	@discardableResult
	mutating func finishLoading(
		provider: RefinementProvider,
		options: [RefinementModelMenuOption]
	) -> Bool {
		guard provider == self.provider else { return false }
		self.options = Self.sorted(options)
		status = options.isEmpty ? .message("No models available") : nil
		return true
	}

	@discardableResult
	mutating func failLoading(
		provider: RefinementProvider,
		message: String,
		disablesRetainedOptions: Bool
	) -> Bool {
		guard provider == self.provider else { return false }
		if disablesRetainedOptions {
			options = options.map { $0.disabled() }
		}
		status = .message(message)
		return true
	}

	static func sorted(_ options: [RefinementModelMenuOption]) -> [RefinementModelMenuOption] {
		options.sorted { lhs, rhs in
			let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
			if comparison == .orderedSame {
				return (lhs.modelID ?? "") < (rhs.modelID ?? "")
			}
			return comparison == .orderedAscending
		}
	}
}

enum RefinementModelMenuTarget: Hashable {
	case rewrite
	case handoff

	var label: String {
		switch self {
		case .rewrite: "Rewrite"
		case .handoff: "Handoff"
		}
	}

	func provider(in settings: HexSettings) -> RefinementProvider {
		switch self {
		case .rewrite: settings.refinementProvider
		case .handoff: settings.agentHandoffProvider
		}
	}
}

enum RefinementModelMenuSelection {
	static func selectedModelID(in settings: HexSettings, target: RefinementModelMenuTarget = .rewrite) -> String? {
		if target == .handoff { return settings.agentHandoffModelID }
		return switch settings.refinementProvider {
		case .openRouter:
			settings.openRouterModelID
		case .openAI:
			settings.openAIModelID ?? settings.openRouterModelID
		case .anthropic:
			settings.anthropicModelID ?? settings.openRouterModelID
		case .codexCLI:
			settings.codexCLIModelID
		case .claudeCLI:
			settings.claudeCLIModelID
		case .apple, .gemini:
			nil
		}
	}

	static func title(
		for settings: HexSettings,
		target: RefinementModelMenuTarget = .rewrite,
		options: [RefinementModelMenuOption]
	) -> String {
		let provider = target.provider(in: settings)
		switch provider {
		case .apple:
			return "Apple Intelligence default"
		case .gemini:
			return "Gemini 3.1 Flash Lite"
		case .codexCLI where selectedModelID(in: settings, target: target) == nil:
			return "Codex default"
		case .claudeCLI where selectedModelID(in: settings, target: target) == nil:
			return "Claude default"
		case .openRouter, .openAI, .anthropic, .codexCLI, .claudeCLI:
			guard let modelID = selectedModelID(in: settings, target: target) else {
				return "Select a model"
			}
			return options.first(where: { $0.modelID == modelID })?.name ?? modelID
		}
	}

	static func displayedOptions(
		for settings: HexSettings,
		target: RefinementModelMenuTarget = .rewrite,
		options: [RefinementModelMenuOption]
	) -> [RefinementModelMenuOption] {
		guard let selectedModelID = selectedModelID(in: settings, target: target),
			  !options.contains(where: { $0.modelID == selectedModelID })
		else { return options }

		let unavailable = RefinementModelMenuOption(
			provider: target.provider(in: settings),
			modelID: selectedModelID,
			name: "\(selectedModelID) (Unavailable)",
			isEnabled: false
		)
		return [unavailable] + options
	}

	static func shortlistedOptions(
		for settings: HexSettings,
		target: RefinementModelMenuTarget = .rewrite,
		options: [RefinementModelMenuOption]
	) -> [RefinementModelMenuOption] {
		guard target.provider(in: settings) == .openRouter else { return options }
		let shortlistedModelIDs = Set(settings.openRouterShortlistedModelIDs)
		return options.filter { option in
			guard let modelID = option.modelID else { return false }
			return shortlistedModelIDs.contains(modelID)
		}
	}

	@discardableResult
	static func apply(
		_ option: RefinementModelMenuOption,
		to settings: inout HexSettings,
		target: RefinementModelMenuTarget = .rewrite
	) -> Bool {
		guard option.isEnabled, option.provider == target.provider(in: settings) else {
			return false
		}
		if target == .handoff {
			settings.agentHandoffModelID = option.modelID
			return true
		}

		switch option.provider {
		case .openRouter:
			settings.openRouterModelID = option.modelID
		case .openAI:
			settings.openAIModelID = option.modelID
		case .anthropic:
			settings.anthropicModelID = option.modelID
		case .codexCLI:
			settings.codexCLIModelID = option.modelID
		case .claudeCLI:
			settings.claudeCLIModelID = option.modelID
		case .apple, .gemini:
			break
		}
		return true
	}
}

enum RefinementModelMenuLoadError: Error, Equatable {
	case missingCredential(String)
	case subscriptionUnavailable(String)

	var menuMessage: String {
		switch self {
		case let .missingCredential(provider):
			"Add \(provider) API key in Settings"
		case let .subscriptionUnavailable(provider):
			"Sign in to \(provider) CLI"
		}
	}
}

struct RefinementModelMenuLoader: Sendable {
	var cachedOptions: @Sendable (RefinementProvider) -> [RefinementModelMenuOption]
	var loadOptions: @Sendable (RefinementProvider) async throws -> [RefinementModelMenuOption]

	static let live = Self(
		cachedOptions: { provider in
			switch provider {
			case .openRouter:
				return OpenRouterModelCatalog.cachedModels()
					.filter { $0.supportsInput(.text) }
					.map {
						.init(
							provider: .openRouter,
							modelID: $0.id,
							name: $0.name,
							isEnabled: true
						)
					}
			case .codexCLI:
				let models = CLIRefinementClient.cachedModels(for: .codex)
				guard !models.isEmpty else { return [] }
				return [
					.init(
						provider: .codexCLI,
						modelID: nil,
						name: "Codex default",
						isEnabled: true
					),
				] + models.map {
					.init(
						provider: .codexCLI,
						modelID: $0.id,
						name: $0.name,
						isEnabled: true
					)
				}
			case .claudeCLI:
				return CLIRefinementClient.cachedModels(for: .claude).map {
					.init(
						provider: .claudeCLI,
						modelID: $0.id == "default" ? nil : $0.id,
						name: $0.name,
						isEnabled: true
					)
				}
			case .apple, .gemini, .openAI, .anthropic:
				return []
			}
		},
		loadOptions: { provider in
			switch provider {
			case .apple:
				return [
					.init(
						provider: .apple,
						modelID: nil,
						name: "Apple Intelligence default",
						isEnabled: true
					),
				]

			case .gemini:
				return [
					.init(
						provider: .gemini,
						modelID: nil,
						name: "Gemini 3.1 Flash Lite",
						isEnabled: true
					),
				]

			case .openRouter:
				guard let apiKey = OpenRouterAPIKeyStore.read(), !apiKey.isEmpty else {
					throw RefinementModelMenuLoadError.missingCredential("OpenRouter")
				}
				return try await OpenRouterModelCatalog.refresh(apiKey: apiKey)
					.filter { $0.supportsInput(.text) }
					.map {
						.init(
							provider: .openRouter,
							modelID: $0.id,
							name: $0.name,
							isEnabled: true
						)
					}

			case .openAI:
				guard let apiKey = OpenAIAPIKeyStore.read(), !apiKey.isEmpty else {
					throw RefinementModelMenuLoadError.missingCredential("OpenAI")
				}
				return try await DirectProviderModelCatalog.refresh(
					provider: .openAI,
					apiKey: apiKey
				)
				.filter { $0.supports(.text) }
				.map {
					.init(
						provider: .openAI,
						modelID: $0.id,
						name: $0.name,
						isEnabled: true
					)
				}

			case .anthropic:
				guard let apiKey = AnthropicAPIKeyStore.read(), !apiKey.isEmpty else {
					throw RefinementModelMenuLoadError.missingCredential("Claude")
				}
				return try await DirectProviderModelCatalog.refresh(
					provider: .anthropic,
					apiKey: apiKey
				)
				.filter { $0.supports(.text) }
				.map {
					.init(
						provider: .anthropic,
						modelID: $0.id,
						name: $0.name,
						isEnabled: true
					)
				}

			case .codexCLI:
				do {
					let models = try await CLIRefinementClient.models(for: .codex)
					return [
						.init(
							provider: .codexCLI,
							modelID: nil,
							name: "Codex default",
							isEnabled: true
						),
					] + models.map {
						.init(
							provider: .codexCLI,
							modelID: $0.id,
							name: $0.name,
							isEnabled: true
						)
					}
				} catch {
					throw RefinementModelMenuLoadError.subscriptionUnavailable("Codex")
				}

			case .claudeCLI:
				do {
					return try await CLIRefinementClient.models(for: .claude)
						.map {
							.init(
								provider: .claudeCLI,
								modelID: $0.id == "default" ? nil : $0.id,
								name: $0.name,
								isEnabled: true
							)
						}
				} catch {
					throw RefinementModelMenuLoadError.subscriptionUnavailable("Claude")
				}
			}
		}
	)
}

@MainActor
struct MenuBarRefinementModelPicker: View {
	@Shared(.hexSettings) private var hexSettings: HexSettings
	@State private var state = RefinementModelMenuState(provider: .apple)

	private let loader: RefinementModelMenuLoader
	private let target: RefinementModelMenuTarget

	init(target: RefinementModelMenuTarget = .rewrite, loader: RefinementModelMenuLoader = .live) {
		self.target = target
		self.loader = loader
	}

	var body: some View {
		Menu {
			let options = RefinementModelMenuSelection.displayedOptions(
				for: hexSettings,
				target: target,
				options: state.provider == provider ? state.options : []
			)
			let shortlistedOptions = RefinementModelMenuSelection.shortlistedOptions(
				for: hexSettings,
				target: target,
				options: options
			)
			let showsShortlist = provider == .openRouter && !shortlistedOptions.isEmpty

			modelOptions(showsShortlist ? shortlistedOptions : options)

			if let status = state.status {
				if !(showsShortlist ? shortlistedOptions : options).isEmpty {
					Divider()
				}
				Text(status.text)
					.foregroundStyle(.secondary)
			}

			if showsShortlist {
				Divider()
				Menu("All Models…") {
					modelOptions(options)
				}
			}
		} label: {
			Text("\(target.label): \(currentModelTitle)")
		}
		.task(id: provider) {
			await loadModels(for: provider)
		}
	}

	private var currentModelTitle: String {
		RefinementModelMenuSelection.title(
			for: hexSettings,
			target: target,
			options: state.provider == provider ? state.options : []
		)
	}

	private var provider: RefinementProvider {
		target.provider(in: hexSettings)
	}

	@ViewBuilder
	private func modelOptions(_ options: [RefinementModelMenuOption]) -> some View {
		ForEach(options) { option in
			Toggle(
				option.name,
				isOn: Binding(
					get: {
						RefinementModelMenuSelection.selectedModelID(in: hexSettings, target: target) == option.modelID
					},
					set: { isSelected in
						guard isSelected else { return }
						$hexSettings.withLock {
							_ = RefinementModelMenuSelection.apply(option, to: &$0, target: target)
						}
					}
				)
			)
			.disabled(!option.isEnabled)
		}
	}

	private func loadModels(for provider: RefinementProvider) async {
		let cachedOptions = loader.cachedOptions(provider)
		state.beginLoading(provider: provider, cachedOptions: cachedOptions)

		do {
			let options = try await loader.loadOptions(provider)
			guard !Task.isCancelled, self.provider == provider else { return }
			state.finishLoading(provider: provider, options: options)
		} catch is CancellationError {
			return
		} catch let error as RefinementModelMenuLoadError {
			guard !Task.isCancelled, self.provider == provider else { return }
			state.failLoading(
				provider: provider,
				message: error.menuMessage,
				disablesRetainedOptions: !cachedOptions.isEmpty
			)
		} catch {
			guard !Task.isCancelled, self.provider == provider else { return }
			state.failLoading(
				provider: provider,
				message: cachedOptions.isEmpty
					? "Couldn't load models"
					: "Couldn't refresh; showing last known models",
				disablesRetainedOptions: !cachedOptions.isEmpty
			)
		}
	}
}

#Preview {
	MenuBarRefinementModelPicker(
		loader: .init(
			cachedOptions: { _ in [] },
			loadOptions: { provider in
				[
					.init(provider: provider, modelID: "example", name: "Example Model", isEnabled: true),
				]
			}
		)
	)
}
