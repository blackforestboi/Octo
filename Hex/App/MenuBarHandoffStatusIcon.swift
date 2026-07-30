import AppKit
import ComposableArchitecture
import SwiftUI

/// Reflects the durable handoff lifecycle in Octo's menu-bar icon.
enum MenuBarHandoffStatus: Equatable, Hashable {
	case idle
	case running
	case completed
	case receiving

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

@MainActor
struct MenuBarHandoffStatusIcon: View {
	@Dependency(\.agentHandoff) private var agentHandoff
	let image: NSImage?
	@State private var status: MenuBarHandoffStatus
	@State private var arrivalPulseTask: Task<Void, Never>?

	init(image: NSImage?) {
		self.image = image
		// The label view is also snapshotted by `MenuBarExtra` during startup.
		// Derive its initial state before that snapshot so a persisted completion
		// is visible immediately after relaunch.
		_status = State(initialValue: Self.loadStatus(using: DependencyValues._current.agentHandoff))
	}

	var body: some View {
		statusIcon
		.onAppear(perform: loadStatus)
		.onReceive(NotificationCenter.default.publisher(for: .agentHandoffJournalDidChange)) { _ in
			loadStatus()
		}
		.onReceive(NotificationCenter.default.publisher(for: .agentHandoffArrivedAtMenuBar)) { _ in
			pulseForArrivingHandoff()
		}
		.onDisappear {
			arrivalPulseTask?.cancel()
		}
		.accessibilityLabel(accessibilityLabel)
	}

	@ViewBuilder
	private var statusIcon: some View {
		if let image {
			Image(nsImage: coloredIcon(from: image))
				.renderingMode(status == .completed || status == .receiving ? .original : .template)
				.id(status)
		} else {
			Image(systemName: "hexagon")
				.imageScale(.small)
				.symbolRenderingMode(status == .completed || status == .receiving ? .multicolor : .monochrome)
				.foregroundStyle(fallbackIconColor)
				.id(status)
		}
	}

	private func coloredIcon(from image: NSImage) -> NSImage {
		switch status {
		case .completed:
			AgentHandoffStatusImages.blueIcon(from: image)
		case .receiving:
			AgentHandoffStatusImages.tintedIcon(from: image, color: .octoIndicator)
		case .idle, .running:
			AgentHandoffStatusImages.templateIcon(from: image)
		}
	}

	private var fallbackIconColor: Color {
		switch status {
		case .completed: Color(nsColor: .systemBlue)
		case .receiving: Color(nsColor: .octoIndicator)
		case .idle, .running: .primary
		}
	}

	private func pulseForArrivingHandoff() {
		arrivalPulseTask?.cancel()
		arrivalPulseTask = Task { @MainActor in
			// Drive the same status-backed redraw path as unread completions, but use
			// the departing dot's color so the two ends of the motion read as one cue.
			for step in 0..<6 {
				guard !Task.isCancelled else { return }
				status = step.isMultiple(of: 2) ? .receiving : .idle
				do {
					try await Task.sleep(for: .milliseconds(220))
				} catch {
					return
				}
			}
			loadStatus()
		}
	}

	private var accessibilityLabel: String {
		switch status {
		case .idle: "Octo"
		case .running: "Octo: agent handoffs running"
		case .completed: "Octo: agent handoffs completed"
		case .receiving: "Octo: agent handoffs received"
		}
	}

	private func loadStatus() {
		status = Self.loadStatus(using: agentHandoff)
	}

	private static func loadStatus(using agentHandoff: AgentHandoffClient) -> MenuBarHandoffStatus {
		do {
			return .status(for: try agentHandoff.tasks())
		} catch {
			return .idle
		}
	}
}

/// `MenuBarExtra` turns SwiftUI colors into template images when it creates
/// AppKit menu items. Use explicitly non-template images so completion updates
/// remain blue in both the menu label and the recent-handoff rows.
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
}
