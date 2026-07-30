import Foundation

extension NSNotification.Name {
  /// Posted when app mode settings change (dock icon visibility, etc.)
  static let updateAppMode = NSNotification.Name("UpdateAppMode")
  static let presentSettingsWindow = NSNotification.Name("PresentSettingsWindow")
	/// Coordinates the departing handoff pill with a brief menu-bar icon pulse.
	static let agentHandoffArrivedAtMenuBar = NSNotification.Name("AgentHandoffArrivedAtMenuBar")
}
