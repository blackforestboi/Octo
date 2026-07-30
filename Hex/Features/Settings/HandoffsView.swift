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
	@State private var deletionError: String?

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
							HandoffTaskCard(task: task, onDelete: delete)
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
		.alert(
			"Couldn't Delete Handoff",
			isPresented: Binding(
				get: { deletionError != nil },
				set: { if !$0 { deletionError = nil } }
			)
		) {
			Button("OK") { deletionError = nil }
		} message: {
			Text(deletionError ?? "")
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

	private func delete(_ task: AgentHandoffTask) {
		do {
			try agentHandoff.deleteTask(task.id)
			tasks.removeAll { $0.id == task.id }
		} catch {
			deletionError = "The saved handoff could not be deleted."
			HexLog.settings.error("Could not delete agent handoff: \(error.localizedDescription, privacy: .private)")
		}
	}
}

private struct HandoffTaskCard: View {
	let task: AgentHandoffTask
	let onDelete: (AgentHandoffTask) -> Void
	@State private var isShowingDeletionConfirmation = false

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(alignment: .top, spacing: 12) {
				VStack(alignment: .leading, spacing: 4) {
					Text(task.title)
						.font(.headline)
					Text("\(providerName) · \(task.createdAt, format: .dateTime.year().month().day().hour().minute())")
						.settingsCaption()
				}

				Spacer()

				Button(role: .destructive, action: { isShowingDeletionConfirmation = true }) {
					Label("Delete handoff", systemImage: "trash")
				}
				.buttonStyle(.borderless)
				.help("Delete handoff")
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
		.confirmationDialog(
			"Delete \(task.title)?",
			isPresented: $isShowingDeletionConfirmation,
			titleVisibility: .visible
		) {
			Button("Delete Handoff", role: .destructive) {
				onDelete(task)
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This removes the saved handoff from Octo. It does not delete the child task.")
		}
	}

	private var providerName: String {
		switch task.provider {
		case .codex: "Codex"
		case .claude: "Claude"
		}
	}
}
