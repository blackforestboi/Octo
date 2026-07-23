import Foundation
import HexCore

/// Loads OpenRouter's catalog and keeps the last successful response available offline.
enum OpenRouterModelCatalog {
	private static let cacheURL = URL.hexStoredFileURL(named: "openrouter_models.json")

	static func cachedModels() -> [OpenRouterModel] {
		guard let data = try? Data(contentsOf: cacheURL),
			  let models = try? JSONDecoder().decode([OpenRouterModel].self, from: data)
		else { return [] }
		return models
	}

	/// Returns the regular OpenRouter model only when the catalog confirms it can
	/// accept an image. Unknown or stale catalog entries deliberately use the
	/// explicit fallback image model instead.
	static func selectedImageCapableModelID(for settings: HexSettings) -> String? {
		guard settings.refinementProvider == .openRouter,
			  let modelID = settings.openRouterModelID,
			  cachedModels().first(where: { $0.id == modelID })?.supportsInput(.image) == true
		else { return nil }
		return modelID
	}

	static func reasoningConfiguration(for modelID: String, requestedEffort: RefinementReasoningEffort) -> OpenRouterReasoningConfiguration? {
		guard let reasoning = cachedModels().first(where: { $0.id == modelID })?.reasoning else {
			return .init(exclude: true)
		}
		let effort: String
		if reasoning.mandatory == true {
			effort = reasoning.supportedEfforts?.contains(requestedEffort.rawValue) == true
				? requestedEffort.rawValue
				: lowestSupportedEffort(in: reasoning.supportedEfforts) ?? "low"
		} else {
			effort = requestedEffort.rawValue
		}
		return .init(effort: effort, exclude: true)
	}

	private static func lowestSupportedEffort(in efforts: [String]?) -> String? {
		let preference = ["minimal", "low", "medium", "high", "xhigh", "max"]
		guard let efforts else { return nil }
		return preference.first(where: { efforts.contains($0) })
	}

	static func refresh(apiKey: String) async throws -> [OpenRouterModel] {
		// Keep every text-output model in one cache. Individual pickers filter this
		// catalog by input modality (text for refinement, image for screen awareness).
		var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text")!)
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		let (data, response) = try await URLSession.shared.data(for: request)
		guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
			throw OpenRouterModelCatalogError.requestFailed
		}

		let models = try JSONDecoder().decode(Response.self, from: data).data
			.filter { !$0.id.isEmpty && !$0.name.isEmpty }
		try save(models)
		return models
	}

	private static func save(_ models: [OpenRouterModel]) throws {
		let data = try JSONEncoder().encode(models)
		try data.write(to: cacheURL, options: .atomic)
	}

	private struct Response: Decodable {
		let data: [OpenRouterModel]
	}

	private enum OpenRouterModelCatalogError: LocalizedError {
		case requestFailed

		var errorDescription: String? { "Could not load OpenRouter models" }
	}
}

struct OpenRouterReasoningConfiguration: Encodable {
	let effort: String?
	let exclude: Bool

	init(effort: String? = nil, exclude: Bool) {
		self.effort = effort
		self.exclude = exclude
	}

	enum CodingKeys: String, CodingKey {
		case effort, exclude
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encodeIfPresent(effort, forKey: .effort)
		try container.encode(exclude, forKey: .exclude)
	}
}
