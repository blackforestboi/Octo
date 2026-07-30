import AppKit
import SwiftUI

extension NSColor {
	/// Accent used for the transient handoff-receiving indicator.
	static var octoIndicator: NSColor {
		.systemRed.blended(withFraction: 0.42, of: .black) ?? .systemRed
	}
}

extension Color {
	/// The shared fill used by raised cards throughout Octo's interface.
	static var octoCardBackground: Color {
		Color(nsColor: .controlBackgroundColor)
	}
}
