import XCTest
@testable import HexCore

final class RefinementTests: XCTestCase {
	func testMissingRefinementSettingsDecodeToSafeDefaults() throws {
		let settings = try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8))
		XCTAssertEqual(settings.refinementMode, .raw)
		XCTAssertEqual(settings.refinementProvider, .apple)
		XCTAssertEqual(settings.refinementReasoningEffort, .none)
			XCTAssertEqual(settings.refinementInstructions, HexSettings.defaultRefinementInstructions)
			XCTAssertNil(settings.openRouterModelID)
			XCTAssertNil(settings.screenAwareOpenRouterModelID)
			XCTAssertEqual(settings.screenAwareInputSource, .localOCR)
	}

	func testRefinementReasoningEffortPersistsAndIsIncludedInRequests() throws {
		let settings = HexSettings(refinementReasoningEffort: .high)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))

		XCTAssertEqual(decoded.refinementReasoningEffort, .high)
		XCTAssertEqual(settings.refinementRequest(for: "draft", mode: .refined).reasoningEffort, .high)
	}

	func testPromptUsesTranscriptDelimitersAndCustomInstructions() {
		let prompt = RefinementPromptBuilder.buildPrompt(
			mode: .refined,
			instructions: "Write in a professional tone.",
			text: "draft email"
		)
		XCTAssertTrue(prompt.contains("<source_text>\ndraft email\n</source_text>"))
		XCTAssertTrue(prompt.contains("primary source material to transform"))
		XCTAssertTrue(prompt.contains("Write in a professional tone."))
	}

	func testSummaryPromptRequiresARealSummaryAndHonorsStructure() {
		let instruction = RefinementPromptBuilder.instruction(
			mode: .summarized,
			instructions: "Return exactly three points: English, French, and German."
		)

		XCTAssertTrue(instruction.contains("instead of repeating it"))
		XCTAssertTrue(instruction.contains("counts, languages, and structure exactly"))
		XCTAssertTrue(instruction.contains("Return exactly three points"))
	}

	func testCleanerKeepsSubstantiveOpeningAndRemovesOnlyPromptTag() {
		XCTAssertEqual(
			RefinementTextProcessor.clean("Text: Here's the project update."),
			"Here's the project update."
		)
	}

	func testCleanerRemovesLeakedThinkingMarkup() {
		XCTAssertEqual(
			RefinementTextProcessor.clean("<think>drafting a response</think>\n\nHello there"),
			"Hello there"
		)
		XCTAssertEqual(RefinementTextProcessor.clean("</think>\nHello there"), "Hello there")
	}

	func testCleanerPreservesQuotedRefinementOutputWithoutPromptTag() {
		XCTAssertEqual(RefinementTextProcessor.clean("\"A quoted sentence.\""), "\"A quoted sentence.\"")
	}

	func testOffScriptGuardAllowsStructuredSummariesOfAnyLengthButRejectsRefinementExpansion() {
		XCTAssertFalse(RefinementTextProcessor.isOffScript(output: "- short", input: "a much longer sentence", mode: .summarized))
		XCTAssertFalse(RefinementTextProcessor.isOffScript(output: String(repeating: "x", count: 250), input: "short", mode: .summarized))
		XCTAssertTrue(RefinementTextProcessor.isOffScript(output: String(repeating: "x", count: 25), input: "short", mode: .refined))
	}

	func testOpenRouterModelDecodesInputPricingAndContextLength() throws {
		let json = """
		{
		  "id": "openai/gpt-4.1-mini",
		  "name": "OpenAI: GPT-4.1 Mini",
			  "pricing": { "prompt": "0.0000004", "completion": "0.0000016" },
			  "architecture": {
			    "input_modalities": ["text", "image"],
			    "output_modalities": ["text"]
			  },
		  "context_length": 1047576
		}
		"""

		let model = try JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8))

		XCTAssertEqual(model.id, "openai/gpt-4.1-mini")
		XCTAssertEqual(model.contextLength, 1_047_576)
			XCTAssertEqual(model.pricing.inputPricePerMillionTokens, Decimal(string: "0.4"))
			XCTAssertTrue(model.supportsInput(.text))
			XCTAssertTrue(model.supportsInput(.image))
	}

	func testOpenRouterModelInputModalityContractDistinguishesTextAndVisionModels() {
		let legacyModel = OpenRouterModel(
			id: "legacy/text-model",
			name: "Legacy Text Model",
			pricing: .init(prompt: "0", completion: "0")
		)
		let textModel = OpenRouterModel(
			id: "provider/text-model",
			name: "Text Model",
			pricing: .init(prompt: "0", completion: "0"),
			architecture: .init(inputModalities: ["text"])
		)
		let visionModel = OpenRouterModel(
			id: "provider/vision-model",
			name: "Vision Model",
			pricing: .init(prompt: "0", completion: "0"),
			architecture: .init(inputModalities: ["text", "image"])
		)

		XCTAssertTrue(legacyModel.supportsInput(.text))
		XCTAssertFalse(legacyModel.supportsInput(.image))
		XCTAssertTrue(textModel.supportsInput(.text))
		XCTAssertFalse(textModel.supportsInput(.image))
		XCTAssertTrue(visionModel.supportsInput(.text))
		XCTAssertTrue(visionModel.supportsInput(.image))
	}

	func testOpenRouterModelDecodesReasoningCapabilities() throws {
		let json = """
		{
		  "id": "provider/reasoning-model",
		  "name": "Reasoning Model",
		  "pricing": { "prompt": "0", "completion": "0" },
		  "reasoning": {
		    "supported_efforts": ["high", "low"],
		    "default_enabled": true,
		    "mandatory": true
		  }
		}
		"""

		let model = try JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8))

		XCTAssertEqual(model.reasoning?.supportedEfforts, ["high", "low"])
		XCTAssertTrue(model.reasoning?.mandatory == true)
	}

	func testRefinementRequestRetainsSelectedOpenRouterModel() {
		let request = RefinementRequest(
			text: "hello",
			mode: .refined,
			instructions: "Return exactly three bullet points.",
			provider: .openRouter,
			modelID: "anthropic/claude-sonnet-4"
		)

		XCTAssertEqual(request.modelID, "anthropic/claude-sonnet-4")
	}

	func testCLIProvidersRoundTripThroughCodableSettings() throws {
		for provider in [RefinementProvider.codexCLI, .claudeCLI] {
			let encoded = try JSONEncoder().encode(provider)
			XCTAssertEqual(try JSONDecoder().decode(RefinementProvider.self, from: encoded), provider)
		}
	}

	func testRefinementUsesTheModelSavedForItsSelectedProvider() {
		let settings = HexSettings(
			refinementProvider: .claudeCLI,
			openAIModelID: "gpt-5.6-sol",
			claudeCLIModelID: "sonnet"
		)

		XCTAssertEqual(settings.refinementRequest(for: "hello", mode: .refined).modelID, "sonnet")
	}

	func testUploadedScreenAwareRequestFallsBackToOpenRouterForCLIProviders() {
		let context = ScreenContext(
			imagePNGData: Data([0x01]),
			recognizedText: "Hello",
			pixelWidth: 1,
			pixelHeight: 1,
			cursorX: 0,
			cursorY: 0
		)

		for provider in [RefinementProvider.codexCLI, .claudeCLI] {
			let settings = HexSettings(refinementProvider: provider, screenAwareInputSource: .image)
			let request = settings.screenAwareRequest(for: "Describe this", context: context)
			XCTAssertEqual(request.provider, .openRouter)
		}
	}

	func testSettingsBuildsRefinementRequest() {
		let settings = HexSettings(
			refinementProvider: .openRouter,
			refinementInstructions: "Use short sentences.",
			openRouterModelID: "openai/gpt-4.1-mini"
		)

		XCTAssertEqual(
			settings.refinementRequest(for: "Draft update", mode: .refined),
			RefinementRequest(
				text: "Draft update",
				mode: .refined,
				instructions: "Use short sentences.",
				provider: .openRouter,
				modelID: "openai/gpt-4.1-mini"
			)
		)
	}

	func testSettingsAddsSpokenInstructionToTheRefinementRequest() {
		let settings = HexSettings(refinementInstructions: "Preserve Markdown.")

		XCTAssertEqual(
			settings.refinementRequest(
				for: "Draft update",
				mode: .refined,
				spokenInstruction: "Make it shorter"
			).instructions,
			"Preserve Markdown.\n\nSpoken instruction:\nMake it shorter"
		)
	}

		func testSettingsKeepsCustomInstructionsWhenThereIsNoSpokenInstruction() {
		let settings = HexSettings(refinementInstructions: "Keep the source details.")

		XCTAssertEqual(
			settings.refinementRequest(for: "Draft update", mode: .refined).instructions,
			"Keep the source details."
		)
		}

		func testSettingsBuildsScreenAwareOpenRouterRequest() {
			let context = ScreenContext(
				imagePNGData: Data([0x01, 0x02]),
				recognizedText: "Account balance",
				pixelWidth: 1920,
				pixelHeight: 1080,
				cursorX: 640,
				cursorY: 480
			)
			let settings = HexSettings(
				refinementProvider: .apple,
				refinementInstructions: "Be concise.",
				screenAwareOpenRouterModelID: "google/gemini-2.5-flash",
				screenAwareDictationEnabled: true,
				screenAwareInputSource: .image
			)

			let request = settings.screenAwareRequest(for: "What is the balance?", context: context)

			XCTAssertTrue(settings.isScreenAwareDictationConfigured)
			XCTAssertEqual(request.provider, .openRouter)
			XCTAssertEqual(request.modelID, "google/gemini-2.5-flash")
			XCTAssertEqual(request.screenContext, context)
			let prompt = ScreenAwarePromptBuilder.prompt(request: request, context: context)
			XCTAssertTrue(prompt.sourceText.contains("What is the balance?"))
			XCTAssertTrue(prompt.sourceText.contains("Account balance"))
			XCTAssertTrue(prompt.sourceText.contains("1920 × 1080"))
		}

	func testScreenAwareRequestCanUseLocalOCRWithoutUploadingTheScreenshot() {
		let context = ScreenContext(
			imagePNGData: Data([0x01, 0x02]),
			recognizedText: "Quarterly revenue: 24% growth",
			pixelWidth: 1920,
			pixelHeight: 1080,
			cursorX: 640,
			cursorY: 480
		)
		let settings = HexSettings(
			screenAwareOpenRouterModelID: "qwen/qwen3.5-flash",
			screenAwareInputSource: .localOCR
		)

		let request = settings.screenAwareRequest(for: "What is the growth?", context: context)
		let prompt = ScreenAwarePromptBuilder.prompt(request: request, context: context)

		XCTAssertEqual(request.screenAwareInputSource, .localOCR)
		XCTAssertFalse(request.screenAwareInputSource.uploadsScreenshot)
		XCTAssertTrue(prompt.systemInstruction.contains("No screenshot is attached."))
		XCTAssertTrue(prompt.sourceText.contains("Quarterly revenue: 24% growth"))
	}

	func testLocalOCRScreenAwareRequestUsesTheSelectedRefinementModel() {
		let context = ScreenContext(
			imagePNGData: Data(),
			recognizedText: "Hello",
			pixelWidth: 1,
			pixelHeight: 1,
			cursorX: 0,
			cursorY: 0
		)
		let settings = HexSettings(
			refinementProvider: .openRouter,
			openRouterModelID: "provider/fast-text-model",
			screenAwareInputSource: .localOCR
		)

		let request = settings.screenAwareRequest(for: "Reply", context: context)

		XCTAssertEqual(request.provider, .openRouter)
		XCTAssertEqual(request.modelID, "provider/fast-text-model")
	}

	func testUploadedScreenAwareRequestUsesTheResolvedImageModel() {
		let context = ScreenContext(
			imagePNGData: Data(),
			recognizedText: "Hello",
			pixelWidth: 1,
			pixelHeight: 1,
			cursorX: 0,
			cursorY: 0
		)
		let settings = HexSettings(
			refinementProvider: .openRouter,
			openRouterModelID: "provider/text-model",
			screenAwareOpenRouterModelID: "provider/fallback-vision-model",
			screenAwareInputSource: .image
		)

		let request = settings.screenAwareRequest(
			for: "Reply",
			context: context,
			imageModelID: "provider/primary-vision-model"
		)

		XCTAssertEqual(request.provider, .openRouter)
		XCTAssertEqual(request.modelID, "provider/primary-vision-model")
	}

	func testScreenAwarePromptUsesFallbackOCRAndPreservesMetadata() {
		let context = ScreenContext(
			imagePNGData: Data([0x01]),
			recognizedText: "",
			pixelWidth: 2560,
			pixelHeight: 1440,
			cursorX: 123.9,
			cursorY: 456.1
		)
		let request = RefinementRequest(
			text: "Summarize the visible error",
			mode: .refined,
			instructions: "  Return one sentence.  ",
			provider: .openRouter,
			modelID: "provider/vision-model",
			screenContext: context
		)

		let prompt = ScreenAwarePromptBuilder.prompt(request: request, context: context)

		XCTAssertTrue(prompt.systemInstruction.contains("Return one sentence."))
		XCTAssertTrue(prompt.systemInstruction.contains("Perform any needed extraction internally"))
		XCTAssertTrue(prompt.systemInstruction.contains("Do not echo a general image description or a full OCR transcript"))
		XCTAssertTrue(prompt.systemInstruction.contains("Output only the direct answer"))
		XCTAssertFalse(prompt.systemInstruction.contains("## Image description"))
		XCTAssertTrue(prompt.systemInstruction.contains("spoken request to decide which visual details"))
		XCTAssertTrue(prompt.sourceText.contains("<spoken_request>\nSummarize the visible error\n</spoken_request>"))
		XCTAssertTrue(prompt.sourceText.contains("spoken request must inform the analysis itself"))
		XCTAssertTrue(prompt.sourceText.contains("Pixel dimensions: 2560 × 1440"))
		XCTAssertTrue(prompt.sourceText.contains("x=123, y=456"))
		XCTAssertTrue(prompt.sourceText.contains("No text was recognized locally."))
	}

	func testScreenAwareConfigurationRejectsWhitespaceOnlyModelID() {
		XCTAssertFalse(HexSettings(screenAwareOpenRouterModelID: nil).isScreenAwareDictationConfigured)
		XCTAssertTrue(HexSettings(screenAwareDictationEnabled: true).isScreenAwareDictationConfigured)
		XCTAssertFalse(HexSettings(screenAwareOpenRouterModelID: "  \n").hasScreenAwareImageFallbackModel)
		XCTAssertTrue(HexSettings(screenAwareOpenRouterModelID: "provider/vision-model").hasScreenAwareImageFallbackModel)
	}

	func testDirectProviderRequestUsesTheSelectedModel() {
		let settings = HexSettings(refinementProvider: .openAI, openRouterModelID: "gpt-5.6")

		let request = settings.refinementRequest(for: "clean this", mode: .refined)

		XCTAssertEqual(request.provider, .openAI)
		XCTAssertEqual(request.modelID, "gpt-5.6")
	}

	func testDirectProviderUsesScreenAwareImageModel() {
		let context = ScreenContext(imagePNGData: Data(), recognizedText: "", pixelWidth: 1, pixelHeight: 1, cursorX: 0, cursorY: 0)
		let settings = HexSettings(
			refinementProvider: .anthropic,
			screenAwareOpenRouterModelID: "claude-sonnet-latest",
			screenAwareInputSource: .image
		)

		let request = settings.screenAwareRequest(for: "describe this", context: context)

		XCTAssertEqual(request.provider, .anthropic)
		XCTAssertEqual(request.modelID, "claude-sonnet-latest")
	}

	func testModifierOnlyHotkeyConflictIsDetected() {
		let regular = HotKey(key: nil, modifiers: [.option])
		let refined = HotKey(key: .space, modifiers: [.option])

		XCTAssertTrue(regular.conflicts(with: refined))
		XCTAssertFalse(regular.conflicts(with: HotKey(key: .space, modifiers: [.command])))
	}
}
