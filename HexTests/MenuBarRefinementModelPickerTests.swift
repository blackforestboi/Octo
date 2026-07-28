import HexCore
import XCTest

@testable import Octo

final class MenuBarRefinementModelPickerTests: XCTestCase {
	func testSelectionReplacesOnlyActiveProviderModel() {
		var settings = HexSettings(
			refinementProvider: .openAI,
			openAIModelID: "old-openai",
			anthropicModelID: "keep-claude"
		)
		let option = RefinementModelMenuOption(
			provider: .openAI,
			modelID: "new-openai",
			name: "New OpenAI",
			isEnabled: true
		)

		XCTAssertTrue(RefinementModelMenuSelection.apply(option, to: &settings))
		XCTAssertEqual(settings.openAIModelID, "new-openai")
		XCTAssertEqual(settings.anthropicModelID, "keep-claude")
	}

	func testSelectionFromPreviousProviderIsIgnored() {
		var settings = HexSettings(
			refinementProvider: .anthropic,
			openAIModelID: "keep-openai",
			anthropicModelID: "keep-claude"
		)
		let staleOption = RefinementModelMenuOption(
			provider: .openAI,
			modelID: "stale-openai",
			name: "Stale OpenAI",
			isEnabled: true
		)

		XCTAssertFalse(RefinementModelMenuSelection.apply(staleOption, to: &settings))
		XCTAssertEqual(settings.openAIModelID, "keep-openai")
		XCTAssertEqual(settings.anthropicModelID, "keep-claude")
	}

	func testLegacyFallbackRemainsVisibleWhenMissingFromCatalog() {
		let settings = HexSettings(
			refinementProvider: .openAI,
			openRouterModelID: "legacy-model"
		)

		XCTAssertEqual(
			RefinementModelMenuSelection.title(for: settings, options: []),
			"legacy-model"
		)

		let displayed = RefinementModelMenuSelection.displayedOptions(
			for: settings,
			options: []
		)
		XCTAssertEqual(displayed.count, 1)
		XCTAssertEqual(displayed[0].name, "legacy-model (Unavailable)")
		XCTAssertEqual(displayed[0].modelID, "legacy-model")
		XCTAssertFalse(displayed[0].isEnabled)
	}

	func testLoadedDisplayNameReplacesRawModelIDInTitle() {
		let settings = HexSettings(
			refinementProvider: .anthropic,
			anthropicModelID: "claude-id"
		)
		let options = [
			RefinementModelMenuOption(
				provider: .anthropic,
				modelID: "claude-id",
				name: "Claude Display Name",
				isEnabled: true
			),
		]

		XCTAssertEqual(
			RefinementModelMenuSelection.title(for: settings, options: options),
			"Claude Display Name"
		)
	}

	func testFixedProviderTitlesAndOptions() {
		let appleSettings = HexSettings(refinementProvider: .apple)
		let geminiSettings = HexSettings(refinementProvider: .gemini)

		XCTAssertEqual(
			RefinementModelMenuSelection.title(for: appleSettings, options: []),
			"Apple Intelligence default"
		)
		XCTAssertEqual(
			RefinementModelMenuSelection.title(for: geminiSettings, options: []),
			"Gemini 3.1 Flash Lite"
		)
	}

	func testStaleProviderCompletionIsDiscarded() {
		var state = RefinementModelMenuState(provider: .openAI)
		state.beginLoading(provider: .openAI, cachedOptions: [])
		state.beginLoading(provider: .anthropic, cachedOptions: [])

		let didApply = state.finishLoading(
			provider: .openAI,
			options: [
				.init(
					provider: .openAI,
					modelID: "stale",
					name: "Stale",
					isEnabled: true
				),
			]
		)

		XCTAssertFalse(didApply)
		XCTAssertEqual(state.provider, .anthropic)
		XCTAssertTrue(state.options.isEmpty)
		XCTAssertEqual(state.status, .loading)
	}

	func testFailedRefreshDisablesRetainedCachedOptions() {
		let cached = RefinementModelMenuOption(
			provider: .openRouter,
			modelID: "cached",
			name: "Cached Model",
			isEnabled: true
		)
		var state = RefinementModelMenuState(provider: .openRouter)
		state.beginLoading(provider: .openRouter, cachedOptions: [cached])

		XCTAssertTrue(
			state.failLoading(
				provider: .openRouter,
				message: "Couldn't refresh; showing last known models",
				disablesRetainedOptions: true
			)
		)
		XCTAssertEqual(state.options.map(\.isEnabled), [false])
		XCTAssertEqual(
			state.status,
			.message("Couldn't refresh; showing last known models")
		)
	}

	func testEmptySuccessfulCatalogShowsEmptyState() {
		var state = RefinementModelMenuState(provider: .openAI)
		state.beginLoading(provider: .openAI, cachedOptions: [])

		XCTAssertTrue(state.finishLoading(provider: .openAI, options: []))
		XCTAssertEqual(state.status, .message("No models available"))
	}

	func testOptionsSortByDisplayNameThenID() {
		let options = [
			RefinementModelMenuOption(
				provider: .openAI,
				modelID: "z",
				name: "Beta",
				isEnabled: true
			),
			RefinementModelMenuOption(
				provider: .openAI,
				modelID: "b",
				name: "Alpha",
				isEnabled: true
			),
			RefinementModelMenuOption(
				provider: .openAI,
				modelID: "a",
				name: "Alpha",
				isEnabled: true
			),
		]

		XCTAssertEqual(
			RefinementModelMenuState.sorted(options).map(\.modelID),
			["a", "b", "z"]
		)
	}
}
