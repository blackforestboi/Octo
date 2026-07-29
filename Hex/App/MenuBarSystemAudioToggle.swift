import ComposableArchitecture
import HexCore
import SwiftUI

/// A pre-recording switch for capturing playback as a separate transcript channel.
struct MenuBarSystemAudioToggle: View {
	@Shared(.hexSettings) private var hexSettings: HexSettings

	var body: some View {
		Toggle(
			"Include System Audio",
			isOn: Binding(
				get: { hexSettings.includeSystemAudio },
				set: { isEnabled in
					$hexSettings.withLock { $0.includeSystemAudio = isEnabled }
				}
			)
		)
	}
}
