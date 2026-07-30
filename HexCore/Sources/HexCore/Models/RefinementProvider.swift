import Foundation

/// Which backend refines a completed transcript.
public enum RefinementProvider: String, Codable, CaseIterable, Equatable, Sendable {
	case apple
	case gemini
	case openRouter
	case openAI
	case anthropic
	case codexCLI
	case claudeCLI
}

extension RefinementProvider {
	/// Returns this provider when it can launch a durable Agent Handoff task.
	public var handoffProvider: Self? {
		switch self {
		case .codexCLI, .claudeCLI: self
		case .apple, .gemini, .openRouter, .openAI, .anthropic: nil
		}
	}
}
