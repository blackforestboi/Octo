import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

/// Reflects the durable handoff lifecycle in Octo's menu-bar icon.
enum MenuBarHandoffStatus: Equatable, Hashable {
	case idle
	case running
	case completed
	case receiving

	var isSpinning: Bool {
		self == .running
	}

	/// An unseen completed handoff is an update the user has not yet acknowledged
	/// in Octo, so it takes precedence over other work that may still be running.
	static func status(for tasks: [AgentHandoffTask]) -> Self {
		if tasks.contains(where: \.hasUnacknowledgedCompletion) {
			return .completed
		}
		if tasks.contains(where: \.isRunning) {
			return .running
		}
		return .idle
	}
}

/// Owns Octo's AppKit status item. Keeping the actual `NSStatusItem` gives the
/// handoff animation a public, live screen-space frame instead of an estimated
/// menu-bar destination.
@MainActor
final class MenuBarStatusItemController: NSObject, NSMenuDelegate {
	private struct HandoffMenuSnapshot: Equatable {
		let tasks: [AgentHandoffTask]
		let processingStatuses: [TranscriptionFeature.AgentHandoffProcessingStatus]
		let activeThreadsByRun: [UUID: Set<AgentHandoffThread>]
	}

	private struct SpinningTaskIcon {
		let item: NSMenuItem
		let frames: [NSImage]
	}

	private final class TaskReference: NSObject {
		let id: UUID
		init(id: UUID) { self.id = id }
	}

	private final class ModelReference: NSObject {
		let option: RefinementModelMenuOption
		let target: RefinementModelMenuTarget

		init(option: RefinementModelMenuOption, target: RefinementModelMenuTarget) {
			self.option = option
			self.target = target
		}
	}

	@Shared(.hexSettings) private var hexSettings: HexSettings
	@Shared(.transcriptionHistory) private var transcriptionHistory: TranscriptionHistory
	@Dependency(\.agentHandoff) private var agentHandoff
	@Dependency(\.pasteboard) private var pasteboard
	@Dependency(\.refinement) private var refinement

	let statusItem: NSStatusItem
	private weak var appDelegate: HexAppDelegate?
	private let menu = NSMenu()
	private let baseImage: NSImage?
	private var status: MenuBarHandoffStatus = .idle
	private var journalStatus: MenuBarHandoffStatus = .idle
	private var shouldRotateStatusItem = false
	private var isPulsingArrival = false
	private var arrivalPulseTask: Task<Void, Never>?
	private var handoffActivityTimer: Timer?
	private var statusItemRotationTimer: Timer?
	private var statusItemRotationFrames: [NSImage] = []
	private var statusItemRotationStyle: MenuBarHandoffStatus?
	private var statusItemRotationFrameIndex = 0
	private var notificationObservers: [NSObjectProtocol] = []
	private var isRefining = false
	private var refineMessage: String?
	private var modelStates: [RefinementModelMenuTarget: RefinementModelMenuState] = [:]
	private var loadedModelProviders: [RefinementModelMenuTarget: RefinementProvider] = [:]
	private var modelLoadTasks: [RefinementModelMenuTarget: Task<Void, Never>] = [:]
	private var visibleModelMenus: [RefinementModelMenuTarget: NSMenu] = [:]
	private var renderedHandoffSnapshot: HandoffMenuSnapshot?
	private var isMenuOpen = false
	private var menuRefreshTimer: Timer?
	private var taskIconAnimationTimer: Timer?
	private var spinningTaskIcons: [SpinningTaskIcon] = []
	private var providerSpinFrames: [String: [NSImage]] = [:]
	private var taskIconFrameIndex = 0

	init(appDelegate: HexAppDelegate) {
		self.appDelegate = appDelegate
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		baseImage = Self.loadBaseImage()
		super.init()

		menu.autoenablesItems = false
		menu.delegate = self
		statusItem.menu = menu
		configureButton()
		loadStatus()
		observeHandoffChanges()
		startHandoffActivityTimer()
	}

	deinit {
		arrivalPulseTask?.cancel()
		modelLoadTasks.values.forEach { $0.cancel() }
		handoffActivityTimer?.invalidate()
		statusItemRotationTimer?.invalidate()
		menuRefreshTimer?.invalidate()
		taskIconAnimationTimer?.invalidate()
		notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
		NSStatusBar.system.removeStatusItem(statusItem)
	}

	/// The status button's exact frame in AppKit's global screen coordinate space.
	/// This is resolved on demand because macOS can move the active menu bar to a
	/// different display after the status item has been created.
	var frameInScreen: NSRect? {
		Self.screenFrame(for: statusItem.button)
	}

	static func screenFrame(for button: NSStatusBarButton?) -> NSRect? {
		guard let button, let window = button.window else { return nil }
		window.layoutIfNeeded()
		let frameInWindow = button.convert(button.bounds, to: nil)
		let frameInScreen = window.convertToScreen(frameInWindow)
		guard frameInScreen.width > 0, frameInScreen.height > 0 else { return nil }
		return frameInScreen
	}

	func menuNeedsUpdate(_: NSMenu) {
		rebuildMenu(using: currentHandoffSnapshot())
	}

	func menuWillOpen(_: NSMenu) {
		isMenuOpen = true
		startOpenMenuRefreshTimer()
		updateTaskIconAnimationTimer()
	}

	func menuDidClose(_: NSMenu) {
		isMenuOpen = false
		menuRefreshTimer?.invalidate()
		menuRefreshTimer = nil
		taskIconAnimationTimer?.invalidate()
		taskIconAnimationTimer = nil
	}

	private func configureButton() {
		guard let button = statusItem.button else { return }
		button.imagePosition = .imageOnly
		button.imageScaling = .scaleProportionallyDown
		button.toolTip = "Octo"
	}

	private func observeHandoffChanges() {
		let center = NotificationCenter.default
		notificationObservers.append(
			center.addObserver(
				forName: .agentHandoffJournalDidChange,
				object: nil,
				queue: .main
			) { [weak self] _ in
				Task { @MainActor in self?.loadStatus() }
			}
		)
		notificationObservers.append(
			center.addObserver(
				forName: .agentHandoffArrivedAtMenuBar,
				object: nil,
				queue: .main
			) { [weak self] _ in
				Task { @MainActor in self?.pulseForArrivingHandoff() }
			}
		)
	}

	private func rebuildMenu(using handoffSnapshot: HandoffMenuSnapshot) {
		menu.removeAllItems()
		visibleModelMenus.removeAll()
		spinningTaskIcons.removeAll()

		let latestText = transcriptionHistory.latestPasteableTranscriptText
		let pasteItem = actionItem("Paste Last Transcript", action: #selector(pasteLastTranscript))
		pasteItem.isEnabled = latestText != nil
		configurePasteShortcut(on: pasteItem)
		menu.addItem(pasteItem)

		if hexSettings.refinementEnabled {
			let title = isRefining ? "Refining Selected Text…" : "Refine Selected Text"
			let refineItem = actionItem(title, action: #selector(refineSelectedText))
			refineItem.isEnabled = !isRefining
			menu.addItem(refineItem)
			addModelPicker(target: .rewrite)
		}

		if hexSettings.agentHandoffEnabled {
			addModelPicker(target: .handoff)
		}

		if let refineMessage {
			menu.addItem(informationalItem(refineMessage))
		}

		menu.addItem(toggleItem(
			"Identify Speakers",
			isOn: hexSettings.speakerIdentificationEnabled,
			action: #selector(toggleSpeakerIdentification)
		))
		menu.addItem(toggleItem(
			"Include System Audio",
			isOn: hexSettings.includeSystemAudio,
			action: #selector(toggleSystemAudio)
		))

		addHandoffItems(from: handoffSnapshot)

		menu.addItem(.separator())
		let historyItem = actionItem("History", action: #selector(openHistory))
		historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
		menu.addItem(historyItem)

		let settingsItem = actionItem("Settings…", action: #selector(openSettings))
		settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
		settingsItem.keyEquivalent = ","
		settingsItem.keyEquivalentModifierMask = [.command]
		menu.addItem(settingsItem)

		let updatesItem = actionItem("Check for Updates…", action: #selector(checkForUpdates))
		updatesItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
		updatesItem.isEnabled = CheckForUpdatesViewModel.shared.canCheckForUpdates
		menu.addItem(updatesItem)

		let quitItem = actionItem("Quit Octo", action: #selector(quit))
		quitItem.keyEquivalent = "q"
		quitItem.keyEquivalentModifierMask = [.command]
		menu.addItem(quitItem)

		renderedHandoffSnapshot = handoffSnapshot
		updateTaskIconAnimationTimer()
	}

	private func addHandoffItems(from snapshot: HandoffMenuSnapshot) {
		let tasks = snapshot.tasks
		let visibleTasks = Array(tasks.filter(\.isOpenable).prefix(10))
		let processingStatuses = snapshot.processingStatuses
		let activeThreads = Set(snapshot.activeThreadsByRun.values.flatMap { $0 })
		guard !visibleTasks.isEmpty || !processingStatuses.isEmpty else { return }

		menu.addItem(.separator())
		if !processingStatuses.isEmpty {
			let provider = processingStatuses.first?.provider ?? .codex
			let providerName = processingStatuses.allSatisfy({ $0.provider == provider })
				? handoffProviderName(provider)
				: "Agents"
			let waitingLabel = MenuBarHandoffProcessingRow.waitingLabel(
				forPendingJobCount: processingStatuses.count
			)
			let item = NSMenuItem(
				title: "\(providerName) · \(waitingLabel)",
				action: nil,
				keyEquivalent: ""
			)
			let frames = spinningFrames(for: provider)
			item.image = frames.first ?? providerImage(for: provider)
			if !frames.isEmpty {
				spinningTaskIcons.append(.init(item: item, frames: frames))
			}
			menu.addItem(item)
		}

		guard !visibleTasks.isEmpty else { return }
		menu.addItem(handoffSectionHeaderItem(
			canMarkAllAsRead: tasks.contains(where: \.hasUnacknowledgedCompletion)
		))
		for task in visibleTasks {
			let item = actionItem(menuLabel(for: task), action: #selector(openHandoffTask(_:)))
			item.representedObject = TaskReference(id: task.id)
			if task.hasUnacknowledgedCompletion {
				item.image = AgentHandoffStatusImages.completedDot
			} else if task.thread.map(activeThreads.contains) == true {
				let frames = spinningFrames(for: task.provider)
				item.image = frames.first ?? providerImage(for: task.provider)
				if !frames.isEmpty {
					spinningTaskIcons.append(.init(item: item, frames: frames))
				}
			} else {
				item.image = providerImage(for: task.provider)
			}
			menu.addItem(item)
		}
	}

	private func handoffProviderName(_ provider: AgentHandoffRequest.Provider) -> String {
		switch provider {
		case .codex: "Codex"
		case .claude: "Claude"
		}
	}

	private func addModelPicker(target: RefinementModelMenuTarget) {
		prepareModels(for: target)
		let provider = target.provider(in: hexSettings)
		let state = modelStates[target] ?? RefinementModelMenuState(provider: provider)
		let title = RefinementModelMenuSelection.title(
			for: hexSettings,
			target: target,
			options: state.provider == provider ? state.options : []
		)
		let item = NSMenuItem(title: "\(target.label): \(title)", action: nil, keyEquivalent: "")
		let submenu = NSMenu()
		submenu.autoenablesItems = false
		populateModelMenu(submenu, target: target)
		item.submenu = submenu
		visibleModelMenus[target] = submenu
		menu.addItem(item)
	}

	private func prepareModels(for target: RefinementModelMenuTarget) {
		let provider = target.provider(in: hexSettings)
		guard loadedModelProviders[target] != provider, modelLoadTasks[target] == nil else { return }
		let cachedOptions = RefinementModelMenuLoader.live.cachedOptions(provider)
		var state = modelStates[target] ?? RefinementModelMenuState(provider: provider)
		state.beginLoading(provider: provider, cachedOptions: cachedOptions)
		modelStates[target] = state

		modelLoadTasks[target] = Task { [weak self] in
			guard let self else { return }
			defer { self.modelLoadTasks[target] = nil }
			do {
				let options = try await RefinementModelMenuLoader.live.loadOptions(provider)
				guard !Task.isCancelled,
					target.provider(in: self.hexSettings) == provider
				else { return }
				self.modelStates[target]?.finishLoading(provider: provider, options: options)
				self.loadedModelProviders[target] = provider
			} catch is CancellationError {
				return
			} catch let error as RefinementModelMenuLoadError {
				self.modelStates[target]?.failLoading(
					provider: provider,
					message: error.menuMessage,
					disablesRetainedOptions: !cachedOptions.isEmpty
				)
				self.loadedModelProviders[target] = provider
			} catch {
				self.modelStates[target]?.failLoading(
					provider: provider,
					message: cachedOptions.isEmpty
						? "Couldn't load models"
						: "Couldn't refresh; showing last known models",
					disablesRetainedOptions: !cachedOptions.isEmpty
				)
				self.loadedModelProviders[target] = provider
			}

			if let submenu = self.visibleModelMenus[target] {
				self.populateModelMenu(submenu, target: target)
			}
		}
	}

	private func populateModelMenu(_ submenu: NSMenu, target: RefinementModelMenuTarget) {
		submenu.removeAllItems()
		let provider = target.provider(in: hexSettings)
		let state = modelStates[target] ?? RefinementModelMenuState(provider: provider)
		let options = RefinementModelMenuSelection.displayedOptions(
			for: hexSettings,
			target: target,
			options: state.provider == provider ? state.options : []
		)
		let shortlist = RefinementModelMenuSelection.shortlistedOptions(
			for: hexSettings,
			target: target,
			options: options
		)
		let showsShortlist = provider == .openRouter && !shortlist.isEmpty
		addModelOptions(showsShortlist ? shortlist : options, to: submenu, target: target)

		if let status = state.status {
			if !submenu.items.isEmpty { submenu.addItem(.separator()) }
			submenu.addItem(informationalItem(status.text))
		}

		if showsShortlist {
			submenu.addItem(.separator())
			let allModelsItem = NSMenuItem(title: "All Models…", action: nil, keyEquivalent: "")
			let allModelsMenu = NSMenu()
			allModelsMenu.autoenablesItems = false
			addModelOptions(options, to: allModelsMenu, target: target)
			allModelsItem.submenu = allModelsMenu
			submenu.addItem(allModelsItem)
		}
	}

	private func addModelOptions(
		_ options: [RefinementModelMenuOption],
		to submenu: NSMenu,
		target: RefinementModelMenuTarget
	) {
		let selectedID = RefinementModelMenuSelection.selectedModelID(in: hexSettings, target: target)
		for option in options {
			let item = actionItem(option.name, action: #selector(selectModel(_:)))
			item.representedObject = ModelReference(option: option, target: target)
			item.state = option.modelID == selectedID ? .on : .off
			item.isEnabled = option.isEnabled
			submenu.addItem(item)
		}
	}

	private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
		item.target = self
		item.isEnabled = true
		return item
	}

	private func toggleItem(_ title: String, isOn: Bool, action: Selector) -> NSMenuItem {
		let item = actionItem(title, action: action)
		item.state = isOn ? .on : .off
		return item
	}

	private func informationalItem(_ title: String) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		item.isEnabled = false
		return item
	}

	private func handoffSectionHeaderItem(canMarkAllAsRead: Bool) -> NSMenuItem {
		let item = NSMenuItem()
		let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
		let label = NSTextField(labelWithString: "Recent Handoffs")
		label.font = .systemFont(ofSize: 11, weight: .semibold)
		label.textColor = .secondaryLabelColor
		label.lineBreakMode = .byTruncatingTail
		label.frame = NSRect(x: 16, y: 3, width: 130, height: 16)
		container.addSubview(label)

		let markAllButton = NSButton(
			title: "Mark All as Read",
			target: self,
			action: #selector(markAllHandoffsAsRead)
		)
		markAllButton.isBordered = false
		markAllButton.focusRingType = .none
		markAllButton.font = .systemFont(ofSize: 10, weight: .semibold)
		markAllButton.contentTintColor = .secondaryLabelColor
		markAllButton.isEnabled = canMarkAllAsRead
		markAllButton.sizeToFit()
		let buttonWidth = min(markAllButton.frame.width, 112)
		markAllButton.frame = NSRect(
			x: container.bounds.width - buttonWidth - 6,
			y: 1,
			width: buttonWidth,
			height: 20
		)
		container.addSubview(markAllButton)

		item.view = container
		return item
	}

	private func configurePasteShortcut(on item: NSMenuItem) {
		guard let hotkey = hexSettings.pasteLastTranscriptHotkey,
			let key = hotkey.key
		else { return }
		item.keyEquivalent = key.rawValue
		var modifiers: NSEvent.ModifierFlags = []
		if hotkey.modifiers.contains(kind: .command) { modifiers.insert(.command) }
		if hotkey.modifiers.contains(kind: .option) { modifiers.insert(.option) }
		if hotkey.modifiers.contains(kind: .shift) { modifiers.insert(.shift) }
		if hotkey.modifiers.contains(kind: .control) { modifiers.insert(.control) }
		item.keyEquivalentModifierMask = modifiers
	}

	@objc private func pasteLastTranscript() {
		guard let text = transcriptionHistory.latestPasteableTranscriptText else { return }
		Task { await pasteboard.paste(text) }
	}

	@objc private func refineSelectedText() {
		guard !isRefining else { return }
		isRefining = true
		refineMessage = nil
		Task { [weak self] in
			guard let self else { return }
			defer { self.isRefining = false }
			guard let selectedText = await self.pasteboard.captureSelectedText() else {
				self.refineMessage = "Select text in another app first."
				return
			}
			do {
				let refinedText = try await self.refinement.refine(
					self.hexSettings.refinementRequest(for: selectedText.text, mode: .refined)
				)
				await self.pasteboard.paste(refinedText)
			} catch is CancellationError {
				selectedText.cancel()
			} catch {
				selectedText.cancel()
				self.refineMessage = "Couldn't refine the selected text."
			}
		}
	}

	@objc private func toggleSpeakerIdentification() {
		$hexSettings.withLock { $0.speakerIdentificationEnabled.toggle() }
	}

	@objc private func toggleSystemAudio() {
		$hexSettings.withLock { $0.includeSystemAudio.toggle() }
	}

	@objc private func openHistory() {
		appDelegate?.presentHistoryView()
	}

	@objc private func openSettings() {
		appDelegate?.presentSettingsView()
	}

	@objc private func checkForUpdates() {
		CheckForUpdatesViewModel.shared.checkForUpdates()
	}

	@objc private func markAllHandoffsAsRead() {
		let taskIDs = ((try? agentHandoff.tasks()) ?? [])
			.filter(\.hasUnacknowledgedCompletion)
			.map(\.id)
		try? agentHandoff.acknowledgeTaskCompletions(taskIDs)
		loadStatus()
	}

	@objc private func openHandoffTask(_ sender: NSMenuItem) {
		guard let id = (sender.representedObject as? TaskReference)?.id,
			let task = ((try? agentHandoff.tasks()) ?? []).first(where: { $0.id == id }),
			let thread = task.thread
		else { return }
		if task.hasUnacknowledgedCompletion {
			try? agentHandoff.acknowledgeTaskCompletions([task.id])
			loadStatus()
		}
		Task { await agentHandoff.open(thread) }
	}

	@objc private func selectModel(_ sender: NSMenuItem) {
		guard let reference = sender.representedObject as? ModelReference else { return }
		$hexSettings.withLock {
			_ = RefinementModelMenuSelection.apply(reference.option, to: &$0, target: reference.target)
		}
	}

	@objc private func quit() {
		NSApplication.shared.terminate(nil)
	}

	private func menuLabel(for task: AgentHandoffTask) -> String {
		switch task.provider {
		case .codex: task.title
		case .claude: "Open in Claude Code: \(task.title)"
		}
	}

	private func providerImage(for provider: AgentHandoffRequest.Provider) -> NSImage? {
		let image = NSImage(named: provider == .codex ? "HandoffOpenAI" : "HandoffClaude")?.copy() as? NSImage
		image?.size = NSSize(width: 13, height: 13)
		return image
	}

	private func spinningFrames(for provider: AgentHandoffRequest.Provider) -> [NSImage] {
		let key = provider == .codex ? "codex" : "claude"
		if let frames = providerSpinFrames[key] { return frames }
		guard let source = providerImage(for: provider) else { return [] }
		let frames = (0..<24).map { frame in
			AgentHandoffStatusImages.rotatedIcon(
				from: source,
				degrees: CGFloat(frame) * 15
			)
		}
		providerSpinFrames[key] = frames
		return frames
	}

	private func currentHandoffSnapshot() -> HandoffMenuSnapshot {
		HandoffMenuSnapshot(
			tasks: (try? agentHandoff.tasks()) ?? [],
			processingStatuses: HexApp.appStore.withState {
				Array($0.transcription.agentHandoffProcessingStatuses)
			},
			activeThreadsByRun: HexApp.appStore.withState {
				$0.transcription.agentHandoffActiveThreads
			}
		)
	}

	private func startHandoffActivityTimer() {
		let timer = Timer(
			timeInterval: 0.25,
			target: self,
			selector: #selector(refreshHandoffActivityTimerFired(_:)),
			userInfo: nil,
			repeats: true
		)
		RunLoop.main.add(timer, forMode: .common)
		handoffActivityTimer = timer
	}

	@objc private func refreshHandoffActivityTimerFired(_: Timer) {
		refreshCombinedHandoffActivity()
	}

	private func updateJournalActivity(from tasks: [AgentHandoffTask]) {
		journalStatus = .status(for: tasks)
	}

	private func refreshCombinedHandoffActivity(
		processingStatuses: [TranscriptionFeature.AgentHandoffProcessingStatus]? = nil,
		activeThreadsByRun: [UUID: Set<AgentHandoffThread>]? = nil
	) {
		let hasProcessingHandoff = !(processingStatuses ?? HexApp.appStore.withState {
			Array($0.transcription.agentHandoffProcessingStatuses)
		}).isEmpty
		let hasActiveHandoffRun = !(activeThreadsByRun ?? HexApp.appStore.withState {
			$0.transcription.agentHandoffActiveThreads
		}).isEmpty
		let rotates = hasActiveHandoffRun || hasProcessingHandoff
		let nextStatus: MenuBarHandoffStatus = journalStatus == .completed
			? .completed
			: (rotates ? .running : .idle)
		let appearanceChanged = status != nextStatus
			|| shouldRotateStatusItem != rotates
			|| statusItem.button?.image == nil
		shouldRotateStatusItem = rotates
		guard !isPulsingArrival, appearanceChanged else { return }
		status = nextStatus
		updateButtonImage()
	}

	private func startOpenMenuRefreshTimer() {
		menuRefreshTimer?.invalidate()
		let timer = Timer(
			timeInterval: 0.35,
			target: self,
			selector: #selector(refreshOpenMenuTimerFired(_:)),
			userInfo: nil,
			repeats: true
		)
		RunLoop.main.add(timer, forMode: .common)
		menuRefreshTimer = timer
	}

	@objc private func refreshOpenMenuTimerFired(_: Timer) {
		refreshOpenMenuIfNeeded()
	}

	private func refreshOpenMenuIfNeeded() {
		guard isMenuOpen else { return }
		let snapshot = currentHandoffSnapshot()
		guard snapshot != renderedHandoffSnapshot else { return }
		updateJournalActivity(from: snapshot.tasks)
		refreshCombinedHandoffActivity(
			processingStatuses: snapshot.processingStatuses,
			activeThreadsByRun: snapshot.activeThreadsByRun
		)
		rebuildMenu(using: snapshot)
	}

	private func scheduleOpenMenuRefresh() {
		guard isMenuOpen else { return }
		DispatchQueue.main.async { [weak self] in
			self?.refreshOpenMenuIfNeeded()
		}
	}

	private func updateTaskIconAnimationTimer() {
		guard isMenuOpen, !spinningTaskIcons.isEmpty else {
			taskIconAnimationTimer?.invalidate()
			taskIconAnimationTimer = nil
			return
		}
		guard taskIconAnimationTimer == nil else { return }

		let timer = Timer(
			timeInterval: 1 / 15,
			target: self,
			selector: #selector(advanceTaskIconAnimation(_:)),
			userInfo: nil,
			repeats: true
		)
		RunLoop.main.add(timer, forMode: .common)
		taskIconAnimationTimer = timer
	}

	@objc private func advanceTaskIconAnimation(_: Timer) {
		taskIconFrameIndex = (taskIconFrameIndex + 1) % 24
		for spinningIcon in spinningTaskIcons where !spinningIcon.frames.isEmpty {
			spinningIcon.item.image = spinningIcon.frames[
				taskIconFrameIndex % spinningIcon.frames.count
			]
		}
	}

	private func loadStatus() {
		updateJournalActivity(from: (try? agentHandoff.tasks()) ?? [])
		refreshCombinedHandoffActivity()
		// A journal notification can arrive while a custom menu control is still
		// handling its click. Refresh on the next run-loop turn so we never remove
		// that control from the menu in the middle of its own action.
		scheduleOpenMenuRefresh()
	}

	private func pulseForArrivingHandoff() {
		arrivalPulseTask?.cancel()
		isPulsingArrival = true
		arrivalPulseTask = Task { [weak self] in
			guard let self else { return }
			for step in 0..<6 {
				guard !Task.isCancelled else { return }
				self.status = step.isMultiple(of: 2) ? .receiving : .idle
				self.updateButtonImage()
				do {
					try await Task.sleep(for: .milliseconds(220))
				} catch {
					return
				}
			}
			self.isPulsingArrival = false
			self.loadStatus()
		}
	}

	private func updateButtonImage() {
		guard let button = statusItem.button else { return }
		let displayImage: NSImage?
		if let baseImage {
			displayImage = switch status {
			case .completed: AgentHandoffStatusImages.blueIcon(from: baseImage)
			case .receiving: AgentHandoffStatusImages.tintedIcon(from: baseImage, color: .octoIndicator)
			case .idle, .running: AgentHandoffStatusImages.templateIcon(from: baseImage)
			}
		} else {
			let fallback = NSImage(systemSymbolName: "hexagon", accessibilityDescription: "Octo")
			displayImage = switch status {
			case .completed: fallback.map { AgentHandoffStatusImages.tintedIcon(from: $0, color: .systemBlue) }
			case .receiving: fallback.map { AgentHandoffStatusImages.tintedIcon(from: $0, color: .octoIndicator) }
			case .idle, .running: fallback
			}
		}

		if shouldRotateStatusItem, !isPulsingArrival, let displayImage {
			startStatusItemRotation(from: displayImage, style: status)
		} else {
			stopStatusItemRotation()
			button.image = displayImage
		}

		button.setAccessibilityLabel(accessibilityLabel)
	}

	private func startStatusItemRotation(from source: NSImage, style: MenuBarHandoffStatus) {
		if statusItemRotationStyle != style || statusItemRotationFrames.isEmpty {
			statusItemRotationFrames = (0..<60).map { frame in
				AgentHandoffStatusImages.rotatedIcon(
					from: source,
					degrees: CGFloat(frame) * 6
				)
			}
			statusItemRotationStyle = style
			statusItemRotationFrameIndex = 0
		}

		statusItem.button?.image = statusItemRotationFrames[statusItemRotationFrameIndex]
		guard statusItemRotationTimer == nil else { return }
		let timer = Timer(
			timeInterval: 1 / 30,
			target: self,
			selector: #selector(advanceStatusItemRotation(_:)),
			userInfo: nil,
			repeats: true
		)
		RunLoop.main.add(timer, forMode: .common)
		statusItemRotationTimer = timer
	}

	@objc private func advanceStatusItemRotation(_: Timer) {
		guard shouldRotateStatusItem,
			!isPulsingArrival,
			!statusItemRotationFrames.isEmpty
		else { return }
		statusItemRotationFrameIndex = (statusItemRotationFrameIndex + 1) % statusItemRotationFrames.count
		statusItem.button?.image = statusItemRotationFrames[statusItemRotationFrameIndex]
	}

	private func stopStatusItemRotation() {
		statusItemRotationTimer?.invalidate()
		statusItemRotationTimer = nil
		statusItemRotationFrames.removeAll(keepingCapacity: true)
		statusItemRotationStyle = nil
		statusItemRotationFrameIndex = 0
	}

	private var accessibilityLabel: String {
		switch status {
		case .idle: "Octo"
		case .running: "Octo: agent handoffs running"
		case .completed: "Octo: agent handoffs completed"
		case .receiving: "Octo: agent handoffs received"
		}
	}

	private static func loadBaseImage() -> NSImage? {
		guard let image = NSImage(named: "OctoMenuBarIcon"), image.size.width > 0 else { return nil }
		let ratio = image.size.height / image.size.width
		image.size = NSSize(width: 20 / ratio, height: 20)
		return image
	}
}

/// Use explicitly non-template images so completion updates remain blue in both
/// the AppKit status button and the recent-handoff rows.
enum AgentHandoffStatusImages {
	static let completedDot: NSImage = {
		let size = NSSize(width: 7, height: 7)
		let image = NSImage(size: size, flipped: false) { rect in
			NSColor.systemBlue.setFill()
			NSBezierPath(ovalIn: rect).fill()
			return true
		}
		image.isTemplate = false
		return image
	}()

	static func blueIcon(from source: NSImage) -> NSImage {
		tintedIcon(from: source, color: .systemBlue)
	}

	static func tintedIcon(from source: NSImage, color: NSColor) -> NSImage {
		let size = source.size
		let image = NSImage(size: size, flipped: false) { rect in
			color.setFill()
			rect.fill()
			source.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
			return true
		}
		image.isTemplate = false
		return image
	}

	static func templateIcon(from source: NSImage) -> NSImage {
		let image = NSImage(size: source.size, flipped: false) { rect in
			source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
			return true
		}
		image.isTemplate = true
		return image
	}

	static func rotatedIcon(from source: NSImage, degrees: CGFloat) -> NSImage {
		let size = source.size
		let image = NSImage(size: size)
		image.lockFocus()
		let transform = NSAffineTransform()
		transform.translateX(by: size.width / 2, yBy: size.height / 2)
		transform.rotate(byDegrees: degrees)
		transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
		transform.concat()
		source.draw(
			in: NSRect(origin: .zero, size: size),
			from: .zero,
			operation: .sourceOver,
			fraction: 1
		)
		image.unlockFocus()
		image.isTemplate = source.isTemplate
		return image
	}
}
