import AppKit
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Sharing

#if canImport(FoundationModels)
import FoundationModels
#endif

private let refinementLogger = HexLog.transcription

/// LLM providers can take substantially longer than URLSession's default 60-second
/// request timeout, especially for multimodal requests. This is deliberately a
/// transport window rather than an application-level generation timeout: Hex leaves
/// the request alive until it completes, fails, or the user explicitly cancels it.
private let longRunningRefinementSession: URLSession = {
	let configuration = URLSessionConfiguration.default
	configuration.timeoutIntervalForRequest = 24 * 60 * 60
	configuration.timeoutIntervalForResource = 24 * 60 * 60
	return URLSession(configuration: configuration)
}()

@DependencyClient
struct RefinementClient {
	var refine: @Sendable (RefinementRequest) async throws -> String = { $0.text }
}

extension RefinementClient: DependencyKey {
	static var liveValue: Self {
		Self(refine: { request in
			guard request.mode != .raw else { return request.text }
			return try await safeRefine(request)
		})
	}

	private static func safeRefine(_ request: RefinementRequest) async throws -> String {
		do {
			return try await refine(request)
		} catch {
			guard isUnsupportedReasoning(error), let fallback = request.reasoningEffort.nextHigher else { throw error }
			let fallbackRequest = request.with(reasoningEffort: fallback)
			let result = try await refine(fallbackRequest)
			@Shared(.hexSettings) var settings: HexSettings
			$settings.withLock { $0.refinementReasoningEffort = fallback }
			return result
		}
	}

	private static func refine(_ request: RefinementRequest) async throws -> String {
			let prompt = if let screenContext = request.screenContext {
				ScreenAwarePromptBuilder.prompt(request: request, context: screenContext)
			} else {
				RefinementPromptBuilder.prompt(
					mode: request.mode,
					instructions: request.instructions,
					text: request.text
				)
			}
		let result = try await process(request, prompt: prompt)
		guard let validatedResult = validated(result) else {
			throw RefinementError.invalidResponse
		}
		return validatedResult
	}

	private static func isUnsupportedReasoning(_ error: Error) -> Bool {
		let message = error.localizedDescription.lowercased()
		return message.contains("reasoning")
			&& (message.contains("not supported") || message.contains("unsupported") || message.contains("invalid"))
	}

	private static func validated(_ output: String) -> String? {
		let cleaned = RefinementTextProcessor.clean(output)
		guard !cleaned.isEmpty,
			  !RefinementTextProcessor.isRefusal(cleaned)
		else { return nil }
		return cleaned
	}

	private static func process(_ request: RefinementRequest, prompt: RefinementPrompt) async throws -> String {
		switch request.provider {
		case .apple:
			#if canImport(FoundationModels)
			if #available(macOS 26.0, *) {
				return try await appleProcess(prompt)
			}
			#endif
			throw RefinementError.providerUnavailable
		case .gemini:
			guard let apiKey = GeminiAPIKeyStore.read(), !apiKey.isEmpty else { throw RefinementError.missingConfiguration }
			return try await geminiProcess(prompt: prompt, apiKey: apiKey, reasoningEffort: request.reasoningEffort)
		case .openRouter:
			guard let apiKey = OpenRouterAPIKeyStore.read(), !apiKey.isEmpty,
				  let modelID = request.modelID, !modelID.isEmpty
			else { throw RefinementError.missingConfiguration }
				return try await openRouterProcess(
					prompt: prompt,
				apiKey: apiKey,
				modelID: modelID,
				reasoningEffort: request.reasoningEffort,
				screenContext: request.screenContext,
					screenAwareInputSource: request.screenAwareInputSource
				)
		case .openAI:
			guard let apiKey = OpenAIAPIKeyStore.read(), !apiKey.isEmpty,
				  let modelID = request.modelID, !modelID.isEmpty
			else { throw RefinementError.missingConfiguration }
			return try await openAIProcess(
				prompt: prompt,
				apiKey: apiKey,
				modelID: modelID,
				reasoningEffort: request.reasoningEffort,
				screenContext: request.screenContext,
				screenAwareInputSource: request.screenAwareInputSource
			)
		case .anthropic:
			guard let apiKey = AnthropicAPIKeyStore.read(), !apiKey.isEmpty,
				  let modelID = request.modelID, !modelID.isEmpty
			else { throw RefinementError.missingConfiguration }
			return try await anthropicProcess(
				prompt: prompt,
				apiKey: apiKey,
				modelID: modelID,
				screenContext: request.screenContext,
				screenAwareInputSource: request.screenAwareInputSource
			)
		case .codexCLI:
			return try await CLIRefinementClient.refine(provider: .codex, prompt: prompt, modelID: request.modelID, reasoningEffort: request.reasoningEffort)
		case .claudeCLI:
			return try await CLIRefinementClient.refine(provider: .claude, prompt: prompt, modelID: request.modelID, reasoningEffort: request.reasoningEffort)
		}
	}

	#if canImport(FoundationModels)
	@available(macOS 26.0, *)
	private static func appleProcess(_ prompt: RefinementPrompt) async throws -> String {
		let session = LanguageModelSession(
			instructions: prompt.systemInstruction
		)
		return try await session.respond(to: prompt.sourceText).content
	}
	#endif

	private static func geminiProcess(prompt: RefinementPrompt, apiKey: String, reasoningEffort: RefinementReasoningEffort) async throws -> String {
		let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent")!
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
		request.httpBody = try JSONEncoder().encode(
			GeminiRequest(
				instruction: prompt.systemInstruction,
				text: prompt.sourceText,
				reasoningEffort: reasoningEffort
			)
		)
		let (data, response) = try await longRunningRefinementSession.data(for: request)
		guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
			throw RefinementError.requestFailed(
				statusCode: (response as? HTTPURLResponse)?.statusCode,
				message: nil
			)
		}
		guard let result = try JSONDecoder().decode(GeminiResponse.self, from: data).text else { throw RefinementError.invalidResponse }
		return result
	}

	private static func openRouterProcess(
			prompt: RefinementPrompt,
			apiKey: String,
			modelID: String,
			reasoningEffort: RefinementReasoningEffort,
			screenContext: ScreenContext?,
			screenAwareInputSource: ScreenAwareInputSource
	) async throws -> String {
		let imageUpload: (data: Data, mimeType: String)? = screenContext.flatMap { context -> (data: Data, mimeType: String)? in
			guard screenAwareInputSource.uploadsScreenshot else { return nil }
			if let jpegData = ScreenAwareImageUpload.jpegData(from: context.imagePNGData),
			   jpegData.count < context.imagePNGData.count {
				return (data: jpegData, mimeType: "image/jpeg")
			}
			return (data: context.imagePNGData, mimeType: "image/png")
		}
		if let screenContext {
			refinementLogger.notice(
				"Submitting screen-aware OpenRouter request model=\(modelID, privacy: .public) source=\(screenAwareInputSource.rawValue, privacy: .public) storedImageBytes=\(screenContext.imagePNGData.count) uploadImageBytes=\(imageUpload?.data.count ?? 0)"
			)
		}
		var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		request.httpBody = try JSONEncoder().encode(
				OpenRouterRequest(
					model: modelID,
					instruction: prompt.systemInstruction,
					text: prompt.sourceText,
					imageData: imageUpload?.data,
					imageMIMEType: imageUpload?.mimeType,
					reasoning: OpenRouterModelCatalog.reasoningConfiguration(for: modelID, requestedEffort: reasoningEffort)
				)
		)
		do {
			let (data, response) = try await longRunningRefinementSession.data(for: request)
			guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
				let statusCode = (response as? HTTPURLResponse)?.statusCode
				let providerMessage = OpenRouterErrorResponse.message(from: data)
				let messageForLog = providerMessage ?? "none"
				refinementLogger.error(
					"OpenRouter request failed status=\(statusCode ?? -1) message=\(messageForLog, privacy: .private)"
				)
				throw RefinementError.requestFailed(statusCode: statusCode, message: providerMessage)
			}
			guard let result = try JSONDecoder().decode(OpenRouterResponse.self, from: data).text else { throw RefinementError.invalidResponse }
			if screenContext != nil {
				refinementLogger.notice(
					"Received screen-aware OpenRouter response model=\(modelID, privacy: .public) outputCharacters=\(result.count)"
				)
			}
			return result
		} catch let error as RefinementError {
			throw error
		} catch {
			refinementLogger.error("OpenRouter transport request failed: \(error.localizedDescription, privacy: .private)")
			throw RefinementError.transportFailed(error.localizedDescription)
		}
	}

	private static func openAIProcess(
		prompt: RefinementPrompt,
		apiKey: String,
		modelID: String,
		reasoningEffort: RefinementReasoningEffort,
		screenContext: ScreenContext?,
		screenAwareInputSource: ScreenAwareInputSource
	) async throws -> String {
		let imageUpload = ScreenAwareImageUpload.upload(for: screenContext, source: screenAwareInputSource)
		var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		request.httpBody = try JSONEncoder().encode(
			OpenAIResponseRequest(
				model: modelID,
				instruction: prompt.systemInstruction,
				text: prompt.sourceText,
				imageData: imageUpload?.data,
				imageMIMEType: imageUpload?.mimeType,
				reasoningEffort: reasoningEffort
			)
		)
		return try await remoteResult(
			request,
			provider: "OpenAI",
			decode: { try JSONDecoder().decode(OpenAIResponse.self, from: $0).text }
		)
	}

	private static func anthropicProcess(
		prompt: RefinementPrompt,
		apiKey: String,
		modelID: String,
		screenContext: ScreenContext?,
		screenAwareInputSource: ScreenAwareInputSource
	) async throws -> String {
		let imageUpload = ScreenAwareImageUpload.upload(for: screenContext, source: screenAwareInputSource)
		var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
		request.httpBody = try JSONEncoder().encode(
			AnthropicMessagesRequest(
				model: modelID,
				instruction: prompt.systemInstruction,
				text: prompt.sourceText,
				imageData: imageUpload?.data,
				imageMIMEType: imageUpload?.mimeType
			)
		)
		return try await remoteResult(
			request,
			provider: "Anthropic",
			decode: { try JSONDecoder().decode(AnthropicMessagesResponse.self, from: $0).text }
		)
	}

	private static func remoteResult(
		_ request: URLRequest,
		provider: String,
		decode: (Data) throws -> String?
	) async throws -> String {
		do {
			let (data, response) = try await longRunningRefinementSession.data(for: request)
			guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
				let statusCode = (response as? HTTPURLResponse)?.statusCode
				let providerMessage = RemoteProviderError.message(from: data)
				refinementLogger.error("\(provider, privacy: .public) request failed status=\(statusCode ?? -1) message=\(providerMessage ?? "none", privacy: .private)")
				throw RefinementError.requestFailed(statusCode: statusCode, message: providerMessage)
			}
			guard let result = try decode(data) else { throw RefinementError.invalidResponse }
			return result
		} catch let error as RefinementError {
			throw error
		} catch {
			refinementLogger.error("\(provider, privacy: .public) transport request failed: \(error.localizedDescription, privacy: .private)")
			throw RefinementError.transportFailed(error.localizedDescription)
		}
	}

	/// Keeps the stored PNG for History while sending a smaller, same-dimension
	/// JPEG to the provider. If conversion fails, the original PNG remains valid input.
	private enum ScreenAwareImageUpload {
		static func upload(for context: ScreenContext?, source: ScreenAwareInputSource) -> (data: Data, mimeType: String)? {
			context.flatMap { context in
				guard source.uploadsScreenshot else { return nil }
				if let jpegData = jpegData(from: context.imagePNGData), jpegData.count < context.imagePNGData.count {
					return (data: jpegData, mimeType: "image/jpeg")
				}
				return (data: context.imagePNGData, mimeType: "image/png")
			}
		}

		static func jpegData(from pngData: Data) -> Data? {
			guard let image = NSImage(data: pngData),
				  let tiffData = image.tiffRepresentation,
				  let bitmap = NSBitmapImageRep(data: tiffData)
			else { return nil }
			return bitmap.representation(
				using: .jpeg,
				properties: [.compressionFactor: 0.92]
			)
		}
	}

	private enum RefinementError: LocalizedError {
		case requestFailed(statusCode: Int?, message: String?)
		case transportFailed(String)
		case invalidResponse, missingConfiguration, providerUnavailable
		var errorDescription: String? {
			switch self {
			case let .requestFailed(statusCode, message):
				let status = statusCode.map { " (HTTP \($0))" } ?? ""
				return "Refinement request failed\(status)\(message.map { ": \($0)" } ?? "")"
			case let .transportFailed(message):
				return "Refinement request failed: \(message)"
			case .invalidResponse:
				return "Refinement returned an invalid response"
			case .missingConfiguration:
				return "Refinement provider is not configured"
			case .providerUnavailable:
				return "Refinement provider is unavailable on this Mac"
			}
		}
	}
}

private struct GeminiRequest: Encodable {
	let systemInstruction: Content
	let contents: [Content]
	let generationConfig: GenerationConfig

	init(instruction: String, text: String, reasoningEffort: RefinementReasoningEffort) {
		systemInstruction = .init(parts: [.init(text: instruction)])
		contents = [.init(parts: [.init(text: text)])]
		generationConfig = .init(reasoningEffort: reasoningEffort)
	}

	struct Content: Encodable { let parts: [Part] }
	struct Part: Encodable { let text: String }
	struct GenerationConfig: Encodable {
		let temperature = 0.2
		let maxOutputTokens = RefinementOutput.maximumTokens
		let thinkingConfig: ThinkingConfig?

		init(reasoningEffort: RefinementReasoningEffort) {
			thinkingConfig = reasoningEffort == .none ? nil : .init(thinkingLevel: reasoningEffort.rawValue)
		}

		struct ThinkingConfig: Encodable {
			let thinkingLevel: String
		}

		enum CodingKeys: String, CodingKey {
			case temperature, thinkingConfig
			case maxOutputTokens = "maxOutputTokens"
		}
	}
}

private struct OpenRouterRequest: Encodable {
	let model: String
	let messages: [Message]
	let reasoning: OpenRouterReasoningConfiguration?
	let temperature = 0.2
	let maxTokens = RefinementOutput.maximumTokens

	init(
		model: String,
		instruction: String,
		text: String,
		imageData: Data? = nil,
		imageMIMEType: String? = nil,
		reasoning: OpenRouterReasoningConfiguration? = nil
	) {
		self.model = model
		self.reasoning = reasoning
		let userContent: Message.Content = if let imageData, let imageMIMEType {
			.parts([
				.text(text),
				.imageURL("data:\(imageMIMEType);base64,\(imageData.base64EncodedString())"),
			])
		} else {
			.text(text)
		}
		messages = [
			.init(role: "system", content: .text(instruction)),
			.init(role: "user", content: userContent),
		]
	}

	struct Message: Encodable {
		let role: String
		let content: Content

		enum Content: Encodable {
			case text(String)
			case parts([Part])

			func encode(to encoder: Encoder) throws {
				var container = encoder.singleValueContainer()
				switch self {
				case let .text(text):
					try container.encode(text)
				case let .parts(parts):
					try container.encode(parts)
				}
			}
		}

		struct Part: Encodable {
			let type: String
			let text: String?
			let imageURL: ImageURL?

			static func text(_ text: String) -> Self {
				.init(type: "text", text: text, imageURL: nil)
			}

			static func imageURL(_ url: String) -> Self {
				.init(type: "image_url", text: nil, imageURL: .init(url: url))
			}

			enum CodingKeys: String, CodingKey {
				case type, text
				case imageURL = "image_url"
			}
		}

		struct ImageURL: Encodable {
			let url: String
		}
	}

	enum CodingKeys: String, CodingKey {
		case model, messages, reasoning, temperature
		case maxTokens = "max_tokens"
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(model, forKey: .model)
		try container.encode(messages, forKey: .messages)
		try container.encode(temperature, forKey: .temperature)
		try container.encode(maxTokens, forKey: .maxTokens)
		try container.encodeIfPresent(reasoning, forKey: .reasoning)
	}
}

private enum RefinementOutput {
	static let maximumTokens = 2_048
}

private struct OpenAIResponseRequest: Encodable {
	let model: String
	let instructions: String
	let input: [Input]
	let maxOutputTokens = RefinementOutput.maximumTokens
	let reasoning: Reasoning?

	init(model: String, instruction: String, text: String, imageData: Data?, imageMIMEType: String?, reasoningEffort: RefinementReasoningEffort) {
		self.model = model
		instructions = instruction
		var content: [Input.Content] = [.text(text)]
		if let imageData, let imageMIMEType {
			content.append(.image("data:\(imageMIMEType);base64,\(imageData.base64EncodedString())"))
		}
		input = [.init(content: content)]
		reasoning = Self.supportsReasoning(model: model, effort: reasoningEffort) ? .init(effort: reasoningEffort.rawValue) : nil
	}

	private static func supportsReasoning(model: String, effort: RefinementReasoningEffort) -> Bool {
		let model = model.lowercased()
		if effort == .none {
			return model.hasPrefix("gpt-5.1") || model.hasPrefix("gpt-5.2") || model.hasPrefix("gpt-5.3") || model.hasPrefix("gpt-5.4") || model.hasPrefix("gpt-5.5") || model.hasPrefix("gpt-5.6")
		}
		return model.hasPrefix("gpt-5") || model.hasPrefix("o")
	}

	struct Reasoning: Encodable { let effort: String }

	struct Input: Encodable {
		let role = "user"
		let content: [Content]

		struct Content: Encodable {
			let type: String
			let text: String?
			let imageURL: String?

			static func text(_ text: String) -> Self { .init(type: "input_text", text: text, imageURL: nil) }
			static func image(_ url: String) -> Self { .init(type: "input_image", text: nil, imageURL: url) }

			enum CodingKeys: String, CodingKey {
				case type, text
				case imageURL = "image_url"
			}
		}
	}

	enum CodingKeys: String, CodingKey {
		case model, instructions, input, reasoning
		case maxOutputTokens = "max_output_tokens"
	}
}

private struct OpenAIResponse: Decodable {
	let outputText: String?
	let output: [Output]?

	var text: String? {
		outputText ?? output?.lazy.compactMap(\.content).joined().first(where: { $0.type == "output_text" })?.text
	}

	struct Output: Decodable { let content: [Content]? }
	struct Content: Decodable { let type: String; let text: String? }

	enum CodingKeys: String, CodingKey {
		case outputText = "output_text"
		case output
	}
}

private struct AnthropicMessagesRequest: Encodable {
	let model: String
	let system: String
	let messages: [Message]
	let maxTokens = RefinementOutput.maximumTokens

	init(model: String, instruction: String, text: String, imageData: Data?, imageMIMEType: String?) {
		self.model = model
		system = instruction
		var content: [Message.Content] = [.text(text)]
		if let imageData, let imageMIMEType {
			content.append(.image(data: imageData.base64EncodedString(), mimeType: imageMIMEType))
		}
		messages = [.init(content: content)]
	}

	struct Message: Encodable {
		let role = "user"
		let content: [Content]

		struct Content: Encodable {
			let type: String
			let text: String?
			let source: Source?

			static func text(_ text: String) -> Self { .init(type: "text", text: text, source: nil) }
			static func image(data: String, mimeType: String) -> Self {
				.init(type: "image", text: nil, source: .init(type: "base64", mediaType: mimeType, data: data))
			}

			struct Source: Encodable {
				let type: String
				let mediaType: String
				let data: String

				enum CodingKeys: String, CodingKey {
					case type, data
					case mediaType = "media_type"
				}
			}
		}
	}

	enum CodingKeys: String, CodingKey {
		case model, system, messages
		case maxTokens = "max_tokens"
	}
}

private struct AnthropicMessagesResponse: Decodable {
	let content: [Content]
	var text: String? { content.first(where: { $0.type == "text" })?.text }
	struct Content: Decodable { let type: String; let text: String? }
}

private struct RemoteProviderError: Decodable {
	let error: Detail?
	let message: String?

	struct Detail: Decodable { let message: String? }

	static func message(from data: Data) -> String? {
		let response = try? JSONDecoder().decode(Self.self, from: data)
		return response?.error?.message ?? response?.message
	}
}

private struct OpenRouterResponse: Decodable {
	let choices: [Choice]

	var text: String? { choices.first?.message.content }

	struct Choice: Decodable {
		let message: Message
	}

	struct Message: Decodable {
		let content: String?
	}
}

private struct OpenRouterErrorResponse: Decodable {
	let error: ErrorDetail?

	struct ErrorDetail: Decodable {
		let message: String?
	}

	static func message(from data: Data) -> String? {
		guard let message = try? JSONDecoder().decode(Self.self, from: data).error?.message else { return nil }
		return String(message.prefix(1_000))
	}
}

private struct GeminiResponse: Decodable {
	let candidates: [Candidate]?
	var text: String? { candidates?.first?.content?.parts?.first?.text }

	struct Candidate: Decodable { let content: Content? }
	struct Content: Decodable { let parts: [Part]? }
	struct Part: Decodable { let text: String? }
}

extension DependencyValues {
	var refinement: RefinementClient {
		get { self[RefinementClient.self] }
		set { self[RefinementClient.self] = newValue }
	}
}
