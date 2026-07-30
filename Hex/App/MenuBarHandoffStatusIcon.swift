import AppKit
import ComposableArchitecture
import SwiftUI

/// Reflects the durable handoff lifecycle in Octo's menu-bar icon.
enum MenuBarHandoffStatus: Equatable {
	case idle
	case running
	case completed

}

@MainActor
struct MenuBarHandoffStatusIcon: View {
	@Dependency(\.agentHandoff) private var agentHandoff
	let image: NSImage?
	@State private var status: MenuBarHandoffStatus = .idle

	var body: some View {
		statusIcon
		.onAppear(perform: loadStatus)
		.onReceive(NotificationCenter.default.publisher(for: .agentHandoffJournalDidChange)) { _ in
			loadStatus()
		}
		.accessibilityLabel(accessibilityLabel)
	}

	@ViewBuilder
	private var statusIcon: some View {
		if status == .completed {
			icon.foregroundStyle(.blue)
		} else {
			icon
		}
	}

	@ViewBuilder
	private var icon: some View {
		if let image {
			Image(nsImage: image)
				.renderingMode(.template)
		} else {
			Image(systemName: "hexagon")
				.imageScale(.small)
		}
	}

	private var accessibilityLabel: String {
		switch status {
		case .idle: "Octo"
		case .running: "Octo: agent handoffs running"
		case .completed: "Octo: agent handoffs completed"
		}
	}

	private func loadStatus() {
		do {
			let tasks = try agentHandoff.tasks()
			if tasks.contains(where: \.isRunning) {
				status = .running
			} else if tasks.contains(where: \.isCompleted) {
				status = .completed
			} else {
				status = .idle
			}
		} catch {
			status = .idle
		}
	}
}
