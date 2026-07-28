import Inject
import SwiftUI
import WebKit

struct SupportView: View {
	@ObserveInjection var inject
	@State private var isLoading = true
	@State private var loadError: Error?
	@State private var reloadID = UUID()

	private static let portalURL = URL(string: "https://octovoice.featurebase.app")!

	var body: some View {
		ZStack {
			FeaturebaseWebView(
				url: Self.portalURL,
				reloadID: reloadID,
				isLoading: $isLoading,
				loadError: $loadError
			)

			if isLoading {
				ProgressView("Loading support…")
			}

			if let loadError {
				VStack(spacing: 12) {
					ContentUnavailableView(
						"Support Is Unavailable",
						systemImage: "questionmark.circle",
						description: Text(loadError.localizedDescription)
					)

					HStack {
					Button("Try Again") {
						reloadID = UUID()
					}
					.buttonStyle(.borderedProminent)

					Link("Open in Browser", destination: Self.portalURL)
					}
				}
			}
		}
		.enableInjection()
	}
}

private struct FeaturebaseWebView: NSViewRepresentable {
	let url: URL
	let reloadID: UUID
	@Binding var isLoading: Bool
	@Binding var loadError: Error?

	func makeCoordinator() -> Coordinator {
		Coordinator(parent: self)
	}

	func makeNSView(context: Context) -> WKWebView {
		let webView = WKWebView()
		webView.navigationDelegate = context.coordinator
		context.coordinator.load(url, in: webView, reloadID: reloadID)
		return webView
	}

	func updateNSView(_ webView: WKWebView, context: Context) {
		context.coordinator.parent = self
		guard context.coordinator.reloadID != reloadID else { return }
		context.coordinator.load(url, in: webView, reloadID: reloadID)
	}

	final class Coordinator: NSObject, WKNavigationDelegate {
		var parent: FeaturebaseWebView
		var reloadID: UUID?

		init(parent: FeaturebaseWebView) {
			self.parent = parent
		}

		func load(_ url: URL, in webView: WKWebView, reloadID: UUID) {
			self.reloadID = reloadID
			parent.isLoading = true
			parent.loadError = nil
			webView.load(URLRequest(url: url))
		}

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			parent.isLoading = false
		}

		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
			handleLoadFailure(error)
		}

		func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
			handleLoadFailure(error)
		}

		func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
			handleLoadFailure(SupportWebViewError.processTerminated)
		}

		private func handleLoadFailure(_ error: Error) {
			guard (error as NSError).code != NSURLErrorCancelled else { return }
			parent.isLoading = false
			parent.loadError = error
		}
	}
}

private enum SupportWebViewError: LocalizedError {
	case processTerminated

	var errorDescription: String? {
		switch self {
		case .processTerminated:
			"The support page stopped unexpectedly. Please try again."
		}
	}
}
