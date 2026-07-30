import ComposableArchitecture
import SwiftUI

/// Keeps the menu-bar handoff shortcuts in sync with the durable journal.
@MainActor
struct MenuBarRecentHandoffs: View {
	@Dependency(\.agentHandoff) private var agentHandoff
	@State private var allTasks: [AgentHandoffTask]

	init() {
		// `MenuBarExtra` constructs its native menu before this view's `onAppear`
		// callback. Seed the state from the journal here so existing handoffs are
		// present in the first menu opened after Octo launches.
		_allTasks = State(initialValue: Self.loadTasks(using: DependencyValues._current.agentHandoff))
	}

	var body: some View {
		Group {
			if !visibleTasks.isEmpty {
				Divider()
				Button(action: markAllTasksAsRead) {
					Label("Mark All as Read", systemImage: "checkmark")
				}
				.disabled(!allTasks.contains(where: \.hasUnacknowledgedCompletion))

				Section("Recent Handoffs") {
					ForEach(visibleTasks) { task in
						Button {
							guard let thread = task.thread else { return }
							if task.hasUnacknowledgedCompletion {
								try? agentHandoff.acknowledgeTaskCompletions([task.id])
								loadTasks()
							}
							Task { await agentHandoff.open(thread) }
						} label: {
							HStack(spacing: 6) {
								if task.hasUnacknowledgedCompletion {
									Image(nsImage: AgentHandoffStatusImages.completedDot)
										.renderingMode(.original)
										.accessibilityLabel("Completed")
								} else {
									providerIcon(for: task.provider)
										.resizable()
										.scaledToFit()
										.frame(width: 13, height: 13)
										.accessibilityLabel(providerName(for: task.provider))
								}

								Text(menuLabel(for: task))
							}
						}
					}
				}
			}
		}
		.onAppear(perform: loadTasks)
		.onReceive(NotificationCenter.default.publisher(for: .agentHandoffJournalDidChange)) { _ in
			loadTasks()
		}
	}

	private func loadTasks() {
		allTasks = Self.loadTasks(using: agentHandoff)
	}

	private func markAllTasksAsRead() {
		let taskIDs = allTasks
			.filter(\.hasUnacknowledgedCompletion)
			.map(\.id)
		try? agentHandoff.acknowledgeTaskCompletions(taskIDs)
		loadTasks()
	}

	private static func loadTasks(using agentHandoff: AgentHandoffClient) -> [AgentHandoffTask] {
		do {
			return try agentHandoff.tasks()
		} catch {
			return []
		}
	}

	private var visibleTasks: [AgentHandoffTask] {
		allTasks
			.filter(\.isOpenable)
			.prefix(10)
			.map { $0 }
	}

	private func providerIcon(for provider: AgentHandoffRequest.Provider) -> Image {
		switch provider {
		case .codex: Image("HandoffOpenAI")
		case .claude: Image("HandoffClaude")
		}
	}

	private func providerName(for provider: AgentHandoffRequest.Provider) -> String {
		switch provider {
		case .codex: "OpenAI"
		case .claude: "Claude"
		}
	}

	private func menuLabel(for task: AgentHandoffTask) -> String {
		switch task.provider {
		case .codex:
			task.title
		case .claude:
			"Open in Claude Code: \(task.title)"
		}
	}
}
