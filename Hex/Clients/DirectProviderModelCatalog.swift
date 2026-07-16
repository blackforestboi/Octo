import Foundation
import HexCore

/// Retrieves the models enabled for the user's own direct-provider credential.
/// The catalog is deliberately refreshed on demand instead of shipping a stale list.
enum DirectProviderModelCatalog {
	struct Model: Identifiable, Equatable, Sendable {
		enum InputModality: Equatable, Sendable {
			case text
			case image
		}

		let id: String
		let name: String
		let createdAt: Date?
		let supportsImage: Bool

		func supports(_ modality: InputModality) -> Bool {
			switch modality {
			case .text: true
			case .image: supportsImage
			}
		}
	}

	enum CatalogError: LocalizedError {
		case requestFailed(statusCode: Int)
		case unsupportedProvider

		var errorDescription: String? {
			switch self {
			case let .requestFailed(statusCode): "Could not load models (HTTP \(statusCode))."
			case .unsupportedProvider: "This provider does not offer a direct model catalog."
			}
		}
	}

	static func refresh(provider: RefinementProvider, apiKey: String) async throws -> [Model] {
		switch provider {
		case .openAI:
			try await openAIModels(apiKey: apiKey)
		case .anthropic:
			try await anthropicModels(apiKey: apiKey)
		case .apple, .gemini, .openRouter:
			throw CatalogError.unsupportedProvider
		}
	}

	private static func openAIModels(apiKey: String) async throws -> [Model] {
		var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
			throw CatalogError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
		}
		return try JSONDecoder().decode(OpenAIResponse.self, from: data).data
			.filter { isOpenAITextModel($0.id) }
			.map { model in
				Model(
					id: model.id,
					name: model.id,
					createdAt: model.created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
					supportsImage: isOpenAIVisionModel(model.id)
				)
			}
			.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
	}

	private static func anthropicModels(apiKey: String) async throws -> [Model] {
		var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1000")!)
		request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
			throw CatalogError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
		}
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try decoder.decode(AnthropicResponse.self, from: data).data
			.filter { $0.id.hasPrefix("claude-") }
			.map { model in
				// All current Claude models support image input. If the API returns an
				// explicit capability list, honor it for future model families too.
				Model(
					id: model.id,
					name: model.displayName ?? model.id,
					createdAt: model.createdAt,
					supportsImage: model.capabilities?.inputModalities?.contains("image") ?? true
				)
			}
			.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
	}

	private static func isOpenAITextModel(_ id: String) -> Bool {
		(id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4"))
			&& !id.contains("image")
			&& !id.contains("audio")
			&& !id.contains("realtime")
	}

	private static func isOpenAIVisionModel(_ id: String) -> Bool {
		id.hasPrefix("gpt-5") || id.hasPrefix("gpt-4o") || id.hasPrefix("gpt-4.1")
			|| id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
	}

	private struct OpenAIResponse: Decodable {
		let data: [OpenAIModel]
	}

	private struct OpenAIModel: Decodable {
		let id: String
		let created: Int?
	}

	private struct AnthropicResponse: Decodable {
		let data: [AnthropicModel]
	}

	private struct AnthropicModel: Decodable {
		let id: String
		let displayName: String?
		let createdAt: Date?
		let capabilities: Capabilities?

		enum CodingKeys: String, CodingKey {
			case id, capabilities
			case displayName = "display_name"
			case createdAt = "created_at"
		}
	}

	private struct Capabilities: Decodable {
		let inputModalities: [String]?

		enum CodingKeys: String, CodingKey {
			case inputModalities = "input_modalities"
		}
	}
}
