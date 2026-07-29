import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

/// Shows the durable child tasks created by Agent Handoffs, including the exact
/// prompt text that Octo delivered to each task.
struct HandoffsView: View {
	@ObserveInjection var inject
	@Dependency(\.agentHandoff) private var agentHandoff
	@State private var tasks: [AgentHandoffTask] = []
	@State private var isLoading = true
	@State private var loadError: String?

	var body: some View {
		Group {
			if isLoading {
				ProgressView("Loading handoffs…")
			} else if let loadError {
				ContentUnavailableView(
					"Handoffs Are Unavailable",
					systemImage: "exclamationmark.triangle",
					description: Text(loadError)
				)
			} else if tasks.isEmpty {
				ContentUnavailableView(
					"No Handoffs Yet",
					systemImage: "arrowshape.turn.up.right",
					description: Text("Finish a recording with the Shift-modified hotkey to create an agent handoff.")
				)
			} else {
				ScrollView(.vertical, showsIndicators: true) {
					LazyVStack(alignment: .leading, spacing: 14) {
						ForEach(tasks) { task in
							HandoffTaskCard(task: task)
						}
					}
					.frame(width: 760, alignment: .leading)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(20)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			}
		}
		.task {
			loadTasks()
		}
		.toolbar {
			Button(action: loadTasks) {
				Label("Refresh Handoffs", systemImage: "arrow.clockwise")
			}
			.help("Refresh handoffs")
		}
		.enableInjection()
	}

	private func loadTasks() {
		isLoading = true
		defer { isLoading = false }
		do {
			tasks = try agentHandoff.tasks()
			loadError = nil
		} catch {
			tasks = []
			loadError = "The saved handoffs could not be read."
			HexLog.settings.error("Could not load agent handoffs: \(error.localizedDescription, privacy: .private)")
		}
	}
}

private struct HandoffTaskCard: View {
	let task: AgentHandoffTask

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			VStack(alignment: .leading, spacing: 4) {
				Text(task.title)
					.font(.headline)
				Text("\(providerName) · \(task.createdAt, format: .dateTime.year().month().day().hour().minute())")
					.settingsCaption()
			}

			Divider()

			Text("Handoff")
				.font(.subheadline.weight(.semibold))
			Text(task.handoff)
				.font(.system(.body, design: .monospaced))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(18)
		.background(Color.octoCardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
	}

	private var providerName: String {
		switch task.provider {
		case .codex: "Codex"
		case .claude: "Claude"
		}
	}
}
