import ComposableArchitecture
import SwiftUI

/// Keeps the menu-bar handoff shortcuts in sync with the durable journal.
@MainActor
struct MenuBarRecentHandoffs: View {
	@Dependency(\.agentHandoff) private var agentHandoff
	@Bindable var store: StoreOf<TranscriptionFeature>
	@State private var allTasks: [AgentHandoffTask]

	init(store: StoreOf<TranscriptionFeature>) {
		self.store = store
		// Seed from the journal before `onAppear` so existing handoffs are present
		// the first time this SwiftUI menu content is rendered.
		_allTasks = State(initialValue: Self.loadTasks(using: DependencyValues._current.agentHandoff))
	}

	var body: some View {
		Group {
			if !visibleTasks.isEmpty || !store.agentHandoffProcessingStatuses.isEmpty {
				Divider()
			}

			if !visibleTasks.isEmpty {
				Button(action: markAllTasksAsRead) {
					Label("Mark All as Read", systemImage: "checkmark")
				}
				.disabled(!allTasks.contains(where: \.hasUnacknowledgedCompletion))
			}

			if !store.agentHandoffProcessingStatuses.isEmpty {
				Section {
					MenuBarHandoffProcessingRow(
						statuses: Array(store.agentHandoffProcessingStatuses)
					)
				}
			}

			if !visibleTasks.isEmpty {
				Section("Recent Handoffs") {
					ForEach(visibleTasks) { task in
						Button {
							guard task.isOpenable, let thread = task.thread else { return }
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
									MenuBarHandoffProviderIcon(
										provider: task.provider,
										isSpinning: task.thread.map(activeThreads.contains) == true
									)
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
		MenuBarRecentHandoffList.visibleTasks(from: allTasks)
	}

	private var activeThreads: Set<AgentHandoffThread> {
		Set(store.agentHandoffActiveThreads.values.flatMap { $0 })
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

struct MenuBarHandoffProcessingRow: View {
	let statuses: [TranscriptionFeature.AgentHandoffProcessingStatus]

	var body: some View {
		HStack(spacing: 8) {
			MenuBarHandoffProviderIcon(provider: iconProvider, isSpinning: true)
				.frame(width: 13, height: 13)

			Text("\(providerName) · \(waitingLabel)")
				.lineLimit(1)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.font(.system(size: 13))
		.padding(.vertical, 2)
		.allowsHitTesting(false)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel("\(providerName) handoff: \(waitingLabel)")
	}

	private var providerName: String {
		guard statuses.allSatisfy({ $0.provider == iconProvider }) else {
			return "Agents"
		}

		switch iconProvider {
		case .codex: return "Codex"
		case .claude: return "Claude"
		}
	}

	private var iconProvider: AgentHandoffRequest.Provider {
		statuses.first?.provider ?? .codex
	}

	private var waitingLabel: String {
		Self.waitingLabel(forPendingJobCount: statuses.count)
	}

	static func waitingLabel(forPendingJobCount count: Int) -> String {
		return "Waiting for \(count) \(count == 1 ? "task" : "tasks")"
	}
}

private struct MenuBarHandoffProviderIcon: View {
	let provider: AgentHandoffRequest.Provider
	let isSpinning: Bool

	var body: some View {
		TimelineView(.animation(minimumInterval: 1 / 30, paused: !isSpinning)) { context in
			providerIcon
				.resizable()
				.scaledToFit()
				.rotationEffect(rotation(at: context.date))
		}
	}

	private var providerIcon: Image {
		switch provider {
		case .codex: Image("HandoffOpenAI")
		case .claude: Image("HandoffClaude")
		}
	}

	private func rotation(at date: Date) -> Angle {
		guard isSpinning else { return .zero }
		let duration = 2.3
		let progress = date.timeIntervalSinceReferenceDate
			.truncatingRemainder(dividingBy: duration) / duration
		return .degrees(progress * 360)
	}
}
