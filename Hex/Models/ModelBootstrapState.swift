import ComposableArchitecture

public enum ModelPreparationPhase: Equatable, Sendable {
	case downloading
	case activating
}

public struct ModelPreparationUpdate: Equatable, Sendable {
	public var phase: ModelPreparationPhase
	public var progress: Double

	public init(phase: ModelPreparationPhase, progress: Double) {
		self.phase = phase
		self.progress = progress
	}
}

struct ModelBootstrapState: Equatable {
    var isModelReady: Bool = false
	var progress: Double = 0
	var preparationPhase: ModelPreparationPhase?
	var lastError: String?
	var modelIdentifier: String?
	var modelDisplayName: String?
}

extension SharedReaderKey
	where Self == InMemoryKey<ModelBootstrapState>.Default
{
	static var modelBootstrapState: Self {
		Self[
			.inMemory("modelBootstrapState"),
			default: .init()
		]
	}
}
