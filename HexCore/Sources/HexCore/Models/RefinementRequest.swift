import Foundation

/// The completed transcript and preferences supplied to the refinement provider.
public struct RefinementRequest: Equatable, Sendable {
	public let text: String
	public let mode: RefinementMode
	public let instructions: String
	public let provider: RefinementProvider
	/// The selected remote-provider model identifier.
	public let modelID: String?
	/// Optional screenshot and locally recognized text for screen-aware requests.
	public let screenContext: ScreenContext?
	/// Whether the screen-aware request includes the screenshot or relies on local OCR only.
	public let screenAwareInputSource: ScreenAwareInputSource

	public init(
		text: String,
		mode: RefinementMode,
		instructions: String,
		provider: RefinementProvider,
		modelID: String? = nil,
		screenContext: ScreenContext? = nil,
		screenAwareInputSource: ScreenAwareInputSource = .image
	) {
		self.text = text
		self.mode = mode
		self.instructions = instructions
		self.provider = provider
		self.modelID = modelID
		self.screenContext = screenContext
		self.screenAwareInputSource = screenAwareInputSource
	}
}
