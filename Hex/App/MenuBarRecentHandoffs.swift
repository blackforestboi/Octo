import ComposableArchitecture
import SwiftUI

/// Keeps the menu-bar handoff shortcuts in sync with the durable journal.
@MainActor
struct MenuBarRecentHandoffs: View {
	@Dependency(\.agentHandoff) private var agentHandoff
	@State private var tasks: [AgentHandoffTask] = []

	var body: some View {
		Group {
			if !tasks.isEmpty {
				Divider()
				Section("Recent Handoffs") {
					ForEach(tasks) { task in
						Button {
							guard let thread = task.thread else { return }
							Task { await agentHandoff.open(thread) }
						} label: {
							HStack(spacing: 6) {
								if task.isCompleted {
									Circle()
										.fill(.blue)
										.frame(width: 7, height: 7)
								} else {
									Image(systemName: providerSymbol(for: task.provider))
								}

								Text(task.title)
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
		do {
			tasks = try agentHandoff.tasks()
				.filter(\.isOpenable)
				.prefix(10)
				.map { $0 }
		} catch {
			tasks = []
		}
	}

	private func providerSymbol(for provider: AgentHandoffRequest.Provider) -> String {
		switch provider {
		case .codex: "bolt.horizontal.circle"
		case .claude: "terminal"
		}
	}
}
