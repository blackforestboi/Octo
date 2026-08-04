import Foundation

struct AgentHandoffMotion: Equatable {
	let backwardDirection: CGSize
	let speed: CGFloat

	static let stationary = Self(backwardDirection: .zero, speed: 0)
}

extension NSNotification.Name {
  /// Posted when app mode settings change (dock icon visibility, etc.)
  static let updateAppMode = NSNotification.Name("UpdateAppMode")
  static let presentSettingsWindow = NSNotification.Name("PresentSettingsWindow")
	static let presentHistoryWindow = NSNotification.Name("PresentHistoryWindow")
	/// Coordinates the departing handoff pill with a brief menu-bar icon pulse.
	static let agentHandoffArrivedAtMenuBar = NSNotification.Name("AgentHandoffArrivedAtMenuBar")
	/// Carries velocity only; the handoff plume remains anchored to the moving dot.
	static let agentHandoffMotionUpdated = NSNotification.Name("AgentHandoffMotionUpdated")
}
