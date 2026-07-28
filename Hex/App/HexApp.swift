import ComposableArchitecture
import Inject
import Sparkle
import AppKit
import SwiftUI

@main
struct HexApp: App {
	static let appStore = Store(initialState: AppFeature.State()) {
		AppFeature()
	}

	@NSApplicationDelegateAdaptor(HexAppDelegate.self) var appDelegate
    var body: some Scene {
        MenuBarExtra {
            MenuBarCopyLastTranscriptButton()
            MenuBarRefineSelectedTextButton()
            MenuBarRefinementModelPicker()

            Button("History") {
                appDelegate.presentHistoryView()
            }

            Button("Settings…") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")

            CheckForUpdatesView()
			
			Divider()
			
			Button("Quit Octo") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			if let image = menuBarIconImage() {
				Image(nsImage: image)
					.renderingMode(.template)
			} else {
				Image(systemName: "hexagon")
					.imageScale(.small)
			}
		}
		.commands {
			CommandGroup(after: .appInfo) {
				CheckForUpdatesView()

				Button("Settings…") {
					appDelegate.presentSettingsView()
				}.keyboardShortcut(",")
			}

			CommandGroup(replacing: .help) {}
		}
	}

	private func menuBarIconImage() -> NSImage? {
		guard let image = NSImage(named: "OctoMenuBarIcon"), image.size.width > 0 else {
			return nil
		}

		let ratio = image.size.height / image.size.width
		image.size = NSSize(width: 18 / ratio, height: 18)
		return image
	}
}
