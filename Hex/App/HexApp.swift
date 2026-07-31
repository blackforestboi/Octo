import ComposableArchitecture
import Inject
import Sparkle
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
    var body: some Scene {
		// AppKit owns the status item so its button window provides the icon's
		// exact global frame. The Settings scene keeps SwiftUI's app/command
		// lifecycle without creating a second menu-bar item.
		Settings {
			EmptyView()
		}
		.commands {
			CommandGroup(replacing: .appSettings) {
				Button("Settings…") {
					appDelegate.presentSettingsView()
				}.keyboardShortcut(",")
			}

			CommandGroup(after: .appInfo) {
				CheckForUpdatesView()
			}

			CommandGroup(replacing: .help) {}
		}
	}
}
