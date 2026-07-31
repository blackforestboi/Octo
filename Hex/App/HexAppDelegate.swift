import ComposableArchitecture
import HexCore
import SwiftUI

private let appLogger = HexLog.app
private let cacheLogger = HexLog.caches

class HexAppDelegate: NSObject, NSApplicationDelegate {
	var invisibleWindow: InvisibleWindow?
	var settingsWindow: NSWindow?
	private(set) var menuBarStatusItemController: MenuBarStatusItemController?
	private var launchedAtLogin = false

	@Dependency(\.soundEffects) var soundEffect
	@Dependency(\.recording) var recording
	@Dependency(\.systemAudioCapture) var systemAudioCapture
	@Shared(.hexSettings) var hexSettings: HexSettings

	func applicationDidFinishLaunching(_: Notification) {
		DiagnosticsLogging.bootstrapIfNeeded()
		// Ensure Parakeet/FluidAudio caches live under Application Support, not ~/.cache
		configureLocalCaches()
		if isTesting {
			appLogger.debug("Running in testing mode")
			return
		}
		configureDockIconForAppearance()
		DistributedNotificationCenter.default().addObserver(
			self,
			selector: #selector(handleAppearanceChange),
			name: Notification.Name("AppleInterfaceThemeChangedNotification"),
			object: nil
		)

		Task {
			await soundEffect.preloadSounds()
			await soundEffect.setEnabled(hexSettings.soundEffectsEnabled)
		}
		launchedAtLogin = wasLaunchedAtLogin()
		appLogger.info("Application did finish launching")
		appLogger.notice("launchedAtLogin = \(self.launchedAtLogin)")

		// Set activation policy first
		updateAppMode()
		// AppKit delivers this lifecycle callback on the main thread, but the
		// legacy delegate protocol is not actor-annotated in Swift 5 mode.
		MainActor.assumeIsolated {
			configureMenuBarStatusItem()
		}

		// Add notification observer
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handleAppModeUpdate),
			name: .updateAppMode,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(handlePresentSettingsWindow),
			name: .presentSettingsWindow,
			object: nil
		)
		// Start long-running app effects (global hotkeys, permissions, etc.)
		startLifecycleTasksIfNeeded()

		// Then present main views
		presentMainView()

		guard shouldOpenForegroundUIOnLaunch else {
			appLogger.notice("Suppressing foreground windows for login launch")
			return
		}

		presentSettingsView()
		NSApp.activate(ignoringOtherApps: true)
	}

	private var shouldOpenForegroundUIOnLaunch: Bool {
		// When Hex launches at login, stay quietly in the menu bar regardless of
		// the dock-icon preference. Users who enabled "Open on Login" expect a
		// background launch; the Settings window can be opened later from the
		// menu bar item or ⌘, when needed.
		!launchedAtLogin
	}

	private func wasLaunchedAtLogin() -> Bool {
		guard let event = NSAppleEventManager.shared().currentAppleEvent else {
			return false
		}

		return event.eventID == AEEventID(kAEOpenApplication)
			&& event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
	}

	private func startLifecycleTasksIfNeeded() {
		Task { @MainActor in
			await HexApp.appStore.send(.task).finish()
		}
	}

	@MainActor
	private func configureMenuBarStatusItem() {
		guard menuBarStatusItemController == nil else { return }
		menuBarStatusItemController = MenuBarStatusItemController(appDelegate: self)
	}

	/// Sets XDG_CACHE_HOME so FluidAudio stores models under our app's
	/// Application Support folder, keeping everything in one place.
    private func configureLocalCaches() {
        do {
            let cache = try URL.hexApplicationSupport.appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            setenv("XDG_CACHE_HOME", cache.path, 1)
            cacheLogger.info("XDG_CACHE_HOME set to \(cache.path)")
        } catch {
            cacheLogger.error("Failed to configure local caches: \(error.localizedDescription)")
        }
    }

	private func configureDockIconForAppearance() {
		let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let iconName = isDark ? "OctoDarkIcon" : "OctoLightIcon"
		guard
			let iconURL = Bundle.main.url(forResource: iconName, withExtension: "png"),
			let icon = NSImage(contentsOf: iconURL)
		else {
			appLogger.error("Unable to load \(iconName) app icon")
			return
		}
		NSApp.applicationIconImage = icon
	}

	func presentMainView() {
		guard invisibleWindow == nil else {
			return
		}
		let transcriptionStore = HexApp.appStore.scope(state: \.transcription, action: \.transcription)
		let transcriptionView = TranscriptionIndicatorOverlayView(
			store: transcriptionStore,
			onOpenHistory: { [weak self] in
				self?.presentHistoryView()
			},
			onPillSizeChange: { [weak self] size, preservingCenter in
				self?.updatePillSize(size, preservingCenter: preservingCenter)
			},
			onAgentHandoffDeparture: { [weak self] in
				// Let SwiftUI finish its status/layout update before the panel begins moving.
				DispatchQueue.main.async {
					guard let self else { return }
					self.invisibleWindow?.animateAgentHandoffDeparture(
						to: self.menuBarStatusItemController?.frameInScreen
					)
				}
			}
		)
		invisibleWindow = InvisibleWindow.fromView(transcriptionView)
		invisibleWindow?.orderFrontRegardless()
	}

	private func updatePillSize(_ size: CGSize?, preservingCenter: Bool = false) {
		invisibleWindow?.update(
			size: size,
			location: hexSettings.indicatorLocation,
			preservingCenter: preservingCenter
		)
	}

	func presentSettingsView() {
		HexApp.appStore.send(.setActiveTab(.settings))
		presentAppWindow()
	}

	func presentHistoryView() {
		HexApp.appStore.send(.setActiveTab(.history))
		presentAppWindow()
	}

	private func presentAppWindow() {
		if let settingsWindow = settingsWindow {
			settingsWindow.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let settingsView = AppView(store: HexApp.appStore)
		let settingsWindow = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 700, height: 700),
			styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		settingsWindow.titleVisibility = .visible
		settingsWindow.contentView = NSHostingView(rootView: settingsView)
		settingsWindow.isReleasedWhenClosed = false
		settingsWindow.minSize = .init(width: 620, height: 560)
		settingsWindow.setFrameAutosaveName("Settings")
		settingsWindow.center()
		settingsWindow.toolbarStyle = NSWindow.ToolbarStyle.unified
		settingsWindow.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		self.settingsWindow = settingsWindow
	}

	@objc private func handleAppModeUpdate() {
		Task {
			await updateAppMode()
		}
	}

	@objc private func handlePresentSettingsWindow() {
		presentSettingsView()
	}

	@objc private func handleAppearanceChange() {
		configureDockIconForAppearance()
	}

	@MainActor
	private func updateAppMode() {
		appLogger.debug("showDockIcon = \(self.hexSettings.showDockIcon)")
		if self.hexSettings.showDockIcon {
			NSApp.setActivationPolicy(.regular)
		} else {
			NSApp.setActivationPolicy(.accessory)
		}
	}

	func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
		// Screen-aware region selection activates the app so its overlay can receive
		// input. Do not interpret that transient activation as a user reopening Octo.
		guard !ScreenCaptureSelectionOverlay.isSelectingRegion else { return true }
		presentSettingsView()
		return true
	}

	func applicationWillTerminate(_: Notification) {
		DistributedNotificationCenter.default().removeObserver(
			self,
			name: Notification.Name("AppleInterfaceThemeChangedNotification"),
			object: nil
		)
		// Wait for audio teardown before the process exits: a fire-and-forget Task here
		// raced process exit, crashing inside AVAudioEngine teardown while tap callbacks
		// were still in flight (#245). Pump the main run loop while waiting instead of
		// blocking outright - cleanup() hops to the main actor/main queue (media-key
		// resume, Core Audio listener removal), which a blocked main thread would deadlock.
		let recording = recording
		let systemAudioCapture = systemAudioCapture
		let semaphore = DispatchSemaphore(value: 0)
		Task.detached {
			async let microphoneCleanup: Void = recording.cleanup()
			async let systemAudioCleanup: Void = systemAudioCapture.cleanup()
			_ = await (microphoneCleanup, systemAudioCleanup)
			semaphore.signal()
		}
		let deadline = Date().addingTimeInterval(3)
		while semaphore.wait(timeout: .now()) == .timedOut {
			guard Date() < deadline else {
				appLogger.error("Audio cleanup timed out during app termination; durable recovery files will be used on next launch")
				return
			}
			RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
		}
	}
}
