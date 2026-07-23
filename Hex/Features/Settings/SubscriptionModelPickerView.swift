import SwiftUI

/// Presents models exposed by a signed-in Codex or Claude subscription runtime.
struct SubscriptionModelPickerView: View {
	@Binding var selectedModelID: String?
	let provider: CLIRefinementClient.Provider
	@Environment(\.dismiss) private var dismiss
	@State private var models: [CLIRefinementClient.Model] = []
	@State private var searchText = ""
	@State private var isRefreshing = false
	@State private var errorMessage: String?

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				HStack(spacing: 12) {
					Text(title).font(.headline)
					TextField("Search models", text: $searchText)
						.textFieldStyle(.roundedBorder)
					Button(action: refresh) {
						if isRefreshing {
							ProgressView()
						} else {
							Image(systemName: "arrow.clockwise")
						}
					}
					.buttonStyle(.borderedProminent)
					.disabled(isRefreshing)
					Button("Close") {
						dismiss()
					}
					.buttonStyle(.bordered)
				}
				.padding()
				Divider()

				if models.isEmpty, isRefreshing {
					ProgressView("Loading available models…")
				} else if models.isEmpty {
					ContentUnavailableView("No Models Available", systemImage: "cpu", description: Text("Sign in to the CLI, then refresh the model list."))
				} else if filteredModels.isEmpty {
					ContentUnavailableView.search(text: searchText)
				} else {
					List(filteredModels) { model in
						Button {
							selectedModelID = model.id
							dismiss()
						} label: {
							HStack {
								VStack(alignment: .leading, spacing: 3) {
									Text(model.name).foregroundStyle(.primary)
									Text(model.id).font(.caption).foregroundStyle(.secondary)
								}
								Spacer()
								if selectedModelID == model.id {
									Image(systemName: "checkmark").foregroundStyle(.tint)
								}
							}
							.contentShape(Rectangle())
						}
						.buttonStyle(.plain)
					}
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			.alert("Couldn’t Refresh Models", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
				Button("OK", role: .cancel) {}
			} message: { Text(errorMessage ?? "Unknown error") }
		}
		.frame(minWidth: 620, minHeight: 520)
		.task { refresh() }
	}

	private var title: String {
		provider == .codex ? "OpenAI Subscription Models" : "Claude Subscription Models"
	}

	private var filteredModels: [CLIRefinementClient.Model] {
		models.filter {
			searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || $0.id.localizedCaseInsensitiveContains(searchText)
		}
	}

	private func refresh() {
		guard !isRefreshing else { return }
		isRefreshing = true
		Task {
			defer { isRefreshing = false }
			do {
				models = try await CLIRefinementClient.models(for: provider)
			} catch is CancellationError {
				return
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}
}
