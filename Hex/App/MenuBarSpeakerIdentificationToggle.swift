import ComposableArchitecture
import HexCore
import SwiftUI

/// A quick, pre-recording switch for the local speaker-identification pass.
struct MenuBarSpeakerIdentificationToggle: View {
	@Shared(.hexSettings) private var hexSettings: HexSettings

	var body: some View {
		Toggle(
			"Identify Speakers",
			isOn: Binding(
				get: { hexSettings.speakerIdentificationEnabled },
				set: { isEnabled in
					$hexSettings.withLock { $0.speakerIdentificationEnabled = isEnabled }
				}
			)
		)
	}
}
