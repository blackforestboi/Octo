import HexCore
import SwiftUI

/// Fetches selectable models from OpenAI or Anthropic for the credential supplied in Settings.
struct DirectProviderModelPickerView: View {
	@Binding var selectedModelID: String?
	let provider: RefinementProvider
	let apiKey: String
	let requiredInputModality: DirectProviderModelCatalog.Model.InputModality
	@Environment(\.dismiss) private var dismiss
	@State private var models: [DirectProviderModelCatalog.Model] = []
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
				}
				.padding()
				Divider()

				if models.isEmpty, isRefreshing {
					ProgressView("Loading available models…")
				} else if models.isEmpty {
					ContentUnavailableView("No Models Available", systemImage: "cpu", description: Text("Check your API key and refresh the catalog."))
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
						}
						.buttonStyle(.plain)
					}
				}
			}
			.alert("Couldn’t Refresh Models", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
				Button("OK", role: .cancel) {}
			} message: { Text(errorMessage ?? "Unknown error") }
		}
		.frame(minWidth: 620, minHeight: 520)
		.task { refresh() }
	}

	private var title: String {
		let source = provider == .openAI ? "OpenAI" : "Claude"
		return requiredInputModality == .image ? "\(source) Vision Models" : "\(source) Models"
	}

	private var filteredModels: [DirectProviderModelCatalog.Model] {
		models.filter { model in
			model.supports(requiredInputModality)
				&& (searchText.isEmpty || model.name.localizedCaseInsensitiveContains(searchText) || model.id.localizedCaseInsensitiveContains(searchText))
		}
	}

	private func refresh() {
		guard !apiKey.isEmpty, !isRefreshing else { return }
		isRefreshing = true
		Task {
			defer { isRefreshing = false }
			do {
				models = try await DirectProviderModelCatalog.refresh(provider: provider, apiKey: apiKey)
			} catch is CancellationError {
				return
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}
}
