import AppKit
import SwiftUI

extension Color {
	/// The shared fill used by raised cards throughout Octo's interface.
	static var octoCardBackground: Color {
		Color(nsColor: .controlBackgroundColor)
	}
}
