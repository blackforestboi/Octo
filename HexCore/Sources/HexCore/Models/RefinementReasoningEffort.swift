import Foundation

/// The amount of model reasoning requested for transcript refinement.
/// Providers that do not support every level use their nearest safe native option.
public enum RefinementReasoningEffort: String, Codable, CaseIterable, Equatable, Sendable {
	case none
	case low
	case medium
	case high

	public var displayName: String {
		switch self {
		case .none: "Off"
		case .low: "Low"
		case .medium: "Medium"
		case .high: "High"
		}
	}

	public var nextHigher: Self? {
		switch self {
		case .none: .low
		case .low: .medium
		case .medium: .high
		case .high: nil
		}
	}
}
