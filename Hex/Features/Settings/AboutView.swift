import ComposableArchitecture
import Inject
import SwiftUI
import Sparkle

struct AboutView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>
    @State var viewModel = CheckForUpdatesViewModel.shared
    @State private var showingChangelog = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("Version", systemImage: "info.circle")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    Button("Check for Updates") {
                        viewModel.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canCheckForUpdates)
                }
                HStack {
                    Label("Changelog", systemImage: "doc.text")
                    Spacer()
                    Button("Show Changelog") {
                        showingChangelog.toggle()
                    }
                    .buttonStyle(.bordered)
                    .sheet(isPresented: $showingChangelog, onDismiss: {
                        showingChangelog = false
                    }) {
                        ChangelogView()
                    }
                }
                HStack {
					Label("Octo is open source", systemImage: "apple.terminal.on.rectangle")
                    Spacer()
					Link("Visit our GitHub", destination: URL(string: "https://github.com/blackforestboi/Octo/")!)
                }
                
                HStack {
                    Label("Support the developer", systemImage: "heart")
                    Spacer()
					Link("Visit Black Forest Boi", destination: URL(string: "https://github.com/blackforestboi")!)
                }
            }
        }
        .formStyle(.grouped)
        .enableInjection()
    }
}
