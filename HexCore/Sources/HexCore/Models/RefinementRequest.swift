import Foundation

/// The completed transcript and preferences supplied to the refinement provider.
public struct RefinementRequest: Equatable, Sendable {
	public let text: String
	public let mode: RefinementMode
	public let instructions: String
	public let provider: RefinementProvider
	/// The requested amount of model reasoning for the refinement.
	public let reasoningEffort: RefinementReasoningEffort
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
		reasoningEffort: RefinementReasoningEffort = .none,
		modelID: String? = nil,
		screenContext: ScreenContext? = nil,
		screenAwareInputSource: ScreenAwareInputSource = .image
	) {
		self.text = text
		self.mode = mode
		self.instructions = instructions
		self.provider = provider
		self.reasoningEffort = reasoningEffort
		self.modelID = modelID
		self.screenContext = screenContext
		self.screenAwareInputSource = screenAwareInputSource
	}

	public func with(reasoningEffort: RefinementReasoningEffort) -> Self {
		.init(
			text: text,
			mode: mode,
			instructions: instructions,
			provider: provider,
			reasoningEffort: reasoningEffort,
			modelID: modelID,
			screenContext: screenContext,
			screenAwareInputSource: screenAwareInputSource
		)
	}
}
