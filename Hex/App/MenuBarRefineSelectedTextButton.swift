import ComposableArchitecture
import Dependencies
import HexCore
import SwiftUI

@MainActor
struct MenuBarRefineSelectedTextButton: View {
  @Shared(.hexSettings) private var hexSettings: HexSettings
  @Dependency(\.pasteboard) private var pasteboard
  @Dependency(\.refinement) private var refinement

  @State private var isRefining = false
  @State private var message: String?

  var body: some View {
    Button(isRefining ? "Refining Selected Text…" : "Refine Selected Text") {
      Task { await refineSelectedText() }
    }
    .disabled(isRefining)

    if let message {
      Text(message)
        .foregroundStyle(.secondary)
    }
  }

  private func refineSelectedText() async {
    isRefining = true
    message = nil
    defer { isRefining = false }

    guard let selectedText = await pasteboard.captureSelectedText() else {
      message = "Select text in another app first."
      return
    }

    do {
      let refinedText = try await refinement.refine(
        hexSettings.refinementRequest(for: selectedText.text, mode: .refined)
      )

      await pasteboard.paste(refinedText)
    } catch is CancellationError {
      selectedText.cancel()
      return
    } catch {
      selectedText.cancel()
      message = "Couldn't refine the selected text."
    }
  }
}

#Preview {
  MenuBarRefineSelectedTextButton()
}
