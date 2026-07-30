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
			MenuBarSpeakerIdentificationToggle()
			MenuBarSystemAudioToggle()

            Button("History") {
                appDelegate.presentHistoryView()
            }

            Button("Settings…") {
                appDelegate.presentSettingsView()
            }.keyboardShortcut(",")

			CheckForUpdatesView()

			MenuBarRecentHandoffs()
			
			Divider()
			
			Button("Quit Octo") {
				NSApplication.shared.terminate(nil)
			}.keyboardShortcut("q")
		} label: {
			MenuBarHandoffStatusIcon(image: menuBarIconImage())
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
		image.size = NSSize(width: 20 / ratio, height: 20)
		return image
	}
}
