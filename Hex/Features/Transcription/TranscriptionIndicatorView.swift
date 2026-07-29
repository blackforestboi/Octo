//
//  TranscriptionIndicatorView.swift
//  Hex
//

import AppKit
import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct TranscriptionIndicatorView: View {
	@ObserveInjection var inject

	enum Status: Equatable {
		case hidden
		case optionKeyPressed
		case recording
		case screenAware
		case transcribing
		case refining
		case prewarming
		case completedTranscript(String)
		case copied(String)
		case hidingCopied(String)
		case error(String)

		var showsWaveform: Bool {
			switch self {
			case .recording, .screenAware: true
			default: false
			}
		}

		var showsProcessing: Bool {
			switch self {
			case .transcribing, .refining, .prewarming: true
			default: false
			}
		}
	}

	private struct Metrics {
		let height: CGFloat
		let waveformWidth: CGFloat

		init(size: IndicatorSize) {
			switch size {
			case .compact:
				height = 22
				waveformWidth = 76
			case .regular:
				height = 28
				waveformWidth = 116
			case .large:
				height = 34
				waveformWidth = 164
			}
		}
	}

	var status: Status
	var meter: Meter
	var size: IndicatorSize
	var availableSize: CGSize = .zero
	var onOpenHistory: () -> Void = {}
	var onCopyCompletedTranscript: () -> Void = {}
	var onDismissCompletedTranscript: () -> Void = {}
	var onCardSizeChange: (CGSize?) -> Void = { _ in }

	@State private var waveformSamples: [CGFloat] = []
	@State private var isHoveringCompletedTranscript = false

	private var metrics: Metrics { .init(size: size) }
	private var isHidden: Bool {
		switch status {
		case .hidden, .hidingCopied:
			true
		default:
			false
		}
	}
	private var hiddenScale: CGFloat { status == .hidden ? 0.8 : 1 }
	private var isScreenAware: Bool { status == .screenAware }
	private var pillCornerRadius: CGFloat { metrics.height * 0.28 }
	private var expandedCardCornerRadius: CGFloat { max(12, pillCornerRadius) }
	private var cardCornerRadius: CGFloat {
		if case .completedTranscript = status { return expandedCardCornerRadius }
		return pillCornerRadius
	}
	private var opensHistoryWhenTapped: Bool {
		switch status {
		case .hidden, .completedTranscript, .copied, .hidingCopied:
			false
		default:
			true
		}
	}

	private var indicatorWidth: CGFloat {
		switch status {
		case .hidden, .optionKeyPressed:
			metrics.height
		case .recording:
			recordingPillSize.width
		case .screenAware:
			// The added room reveals older waveform samples instead of resetting them.
			metrics.waveformWidth + 58
		case .transcribing, .refining, .prewarming:
			// Loading is a continuation of recording, so retain the recording pill's width.
			recordingPillSize.width
		case let .completedTranscript(text):
			expandedSize(for: text).width
		case .copied, .hidingCopied:
			recordingPillSize.width
		case .error:
			300
		}
	}

	private var indicatorHeight: CGFloat {
		if case let .completedTranscript(text) = status {
			return expandedSize(for: text).height
		}
		return metrics.height
	}

	private var cardSize: CGSize {
		.init(width: indicatorWidth, height: indicatorHeight)
	}

	private func expandedSize(for text: String) -> CGSize {
		let maximumSize = maximumTranscriptCardSize
		return .init(
			width: maximumSize.width,
			height: transcriptCardHeight(for: text, width: maximumSize.width, maximum: maximumSize.height)
		)
	}

	private var maximumTranscriptCardSize: CGSize {
		let proposedWidth = recordingPillSize.width * 3
		let proposedMaximumHeight = metrics.height * 5
		guard availableSize.width > 0, availableSize.height > 0 else {
			return .init(width: proposedWidth, height: proposedMaximumHeight)
		}
		return .init(
			width: min(proposedWidth, max(metrics.height * 4, availableSize.width - 48)),
			height: min(proposedMaximumHeight, max(metrics.height * 3, availableSize.height - 36))
		)
	}

	private func transcriptCardHeight(for text: String, width: CGFloat, maximum: CGFloat) -> CGFloat {
		let textBounds = (text as NSString).boundingRect(
			with: .init(width: max(1, width - 28), height: .greatestFiniteMagnitude),
			options: [.usesLineFragmentOrigin, .usesFontLeading],
			attributes: [.font: NSFont.systemFont(ofSize: 14)],
			context: nil
		)
		let minimum = min(maximum, metrics.height * 2.5)
		return min(maximum, max(minimum, ceil(textBounds.height) + 28))
	}

	private var waveformWidth: CGFloat {
		metrics.waveformWidth + (isScreenAware ? 24 : 0)
	}

	/// The copied confirmation reuses the exact recording-pill geometry.
	private var recordingPillSize: CGSize {
		.init(width: metrics.waveformWidth + 20, height: metrics.height)
	}

	private var accessibilityLabel: String {
		switch status {
		case .hidden: "Dictation inactive"
		case .optionKeyPressed: "Dictation hotkey pressed"
		case .recording: "Recording"
		case .screenAware: "Screen aware recording"
		case .transcribing: "Transcribing"
		case .refining: "Refining"
		case .prewarming: "Model prewarming"
		case .completedTranscript: "Transcript ready to copy"
		case .copied: "Transcript copied"
		case .hidingCopied: "Transcript copied"
		case let .error(message): "Error: \(message)"
		}
	}

	@ViewBuilder
	var body: some View {
		if opensHistoryWhenTapped {
			indicatorBody.onTapGesture(perform: onOpenHistory)
		} else {
			indicatorBody
		}
	}

	private var indicatorBody: some View {
		visualCard
			.opacity(isHidden ? 0 : 1)
			.scaleEffect(hiddenScale)
			.accessibilityLabel(accessibilityLabel)
			.accessibilityHidden(isHidden)
			.onAppear {
				appendMeterSample(meter)
				onCardSizeChange(isHidden ? nil : cardSize)
			}
			.onChange(of: meter) { _, meter in
				appendMeterSample(meter)
			}
			.onChange(of: status) { oldStatus, newStatus in
				if oldStatus.showsWaveform && !newStatus.showsWaveform {
					waveformSamples.removeAll(keepingCapacity: true)
				}
				if case .completedTranscript = newStatus {
					onCardSizeChange(cardSize)
				} else {
					isHoveringCompletedTranscript = false
					onCardSizeChange(isHidden ? nil : cardSize)
				}
			}
			.onChange(of: size) { _, _ in
				onCardSizeChange(isHidden ? nil : cardSize)
			}
			.enableInjection()
	}

	private var visualCard: some View {
		ZStack {
			cardSurface
				.frame(width: cardSize.width, height: cardSize.height)

			content
				.frame(width: cardSize.width, height: cardSize.height)
		}
			.frame(width: cardSize.width, height: cardSize.height)
	}

	private var cardSurface: some View {
		RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
			.fill(backgroundStyle)
			.overlay {
				if usesGlassBackground {
					RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
						.fill(Color(nsColor: .windowBackgroundColor).opacity(0.68))
				}
			}
			.overlay {
				RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
					.stroke(strokeColor, lineWidth: 1)
			}
	}

	@ViewBuilder
	private var content: some View {
		if status.showsWaveform {
			HStack(spacing: isScreenAware ? 6 : 0) {
				if isScreenAware {
					Image(systemName: "rectangle.inset.filled")
						.font(.system(size: metrics.height * 0.42, weight: .semibold))
						.foregroundStyle(.white)
						.help("Screen aware")
				}

				PillWaveform(samples: waveformSamples)
					.frame(width: waveformWidth, height: metrics.height - 8)
			}
			.padding(.horizontal, 10)
		} else if status == .refining {
			LoadingWave(label: "Refining", width: metrics.waveformWidth, height: metrics.height)
		} else if status.showsProcessing {
			LoadingWave(label: "Processing", width: metrics.waveformWidth, height: metrics.height)
		} else if case let .completedTranscript(text) = status {
			completedTranscript(text)
		} else if case .copied = status {
			copiedLabel
		} else if case .hidingCopied = status {
			copiedLabel
		} else if case let .error(message) = status {
			Label(message, systemImage: "exclamationmark.triangle.fill")
				.font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.white)
				.lineLimit(2)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 10)
		}
	}

	private func completedTranscript(_ text: String) -> some View {
		ZStack(alignment: .topTrailing) {
			ScrollView(.vertical) {
				VStack(alignment: .leading, spacing: 0) {
					Text(text)
						.font(.system(size: 14))
						.foregroundStyle(.primary)
						.frame(maxWidth: .infinity, alignment: .leading)
						.textSelection(.enabled)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(14)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

			if isHoveringCompletedTranscript {
				ZStack(alignment: .topTrailing) {
					Button(action: onCopyCompletedTranscript) {
						ZStack {
							RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
								.fill(.thinMaterial)
								.opacity(0.48)
								.accessibilityHidden(true)

							Label("Click to Copy", systemImage: "doc.on.doc")
								.font(.system(size: 15, weight: .semibold))
								.padding(.horizontal, 18)
								.padding(.vertical, 12)
						}
						.frame(maxWidth: .infinity, maxHeight: .infinity)
					}
					.buttonStyle(.plain)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
					.accessibilityLabel("Copy to Clipboard")
					.accessibilityHint("Copies the completed transcript")

					Button(action: onDismissCompletedTranscript) {
						Image(systemName: "xmark.circle.fill")
							.font(.system(size: 28, weight: .semibold))
							.symbolRenderingMode(.hierarchical)
							.foregroundStyle(.primary)
							.padding(10)
					}
					.buttonStyle(.plain)
					.accessibilityLabel("Dismiss transcript")
					.accessibilityHint("Closes the transcript without copying it")
					.help("Close")
				}
				.clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
		.onHover { isHoveringCompletedTranscript = $0 }
		.accessibilityElement(children: .contain)
	}

	private var copiedLabel: some View {
		Label("Copied", systemImage: "checkmark")
			.font(.system(size: max(10, metrics.height * 0.38), weight: .semibold))
			.foregroundStyle(.white)
	}

	private var backgroundStyle: AnyShapeStyle {
		if case .completedTranscript = status { return AnyShapeStyle(.regularMaterial) }
		return AnyShapeStyle(isHidden ? .clear : Color(nsColor: mixedNSColor(.systemRed, with: .black, by: 0.42)))
	}

	private var usesGlassBackground: Bool {
		if case .completedTranscript = status { return true }
		return false
	}

	private var strokeColor: Color {
		if case .completedTranscript = status { return .primary.opacity(0.16) }
		return isHidden ? Color.clear : Color.white.opacity(0.28)
	}

	private func appendMeterSample(_ meter: Meter) {
		guard status.showsWaveform else { return }
		// Typical spoken audio spends most of its time well below the peak meter
		// range. Boost and curve that lower range so normal speech remains legible.
		let boostedLevel = min(max(max(meter.averagePower, meter.peakPower * 0.88) * 7.5, 0), 1)
		let sample = CGFloat(pow(boostedLevel, 0.55))
		waveformSamples.append(sample)
		if waveformSamples.count > 240 {
			waveformSamples.removeFirst(waveformSamples.count - 240)
		}
	}

	private func mixedNSColor(_ color: NSColor, with otherColor: NSColor, by fraction: Double) -> NSColor {
		color.blended(withFraction: min(max(fraction, 0), 1), of: otherColor) ?? color
	}
}

private struct PillWaveform: View {
	let samples: [CGFloat]

	var body: some View {
		Canvas { context, size in
			let barWidth: CGFloat = 3
			let gap: CGFloat = 2
			let capacity = max(1, Int((size.width + gap) / (barWidth + gap)))
			let visibleSamples = samples.suffix(capacity)
			let values = visibleSamples.isEmpty ? Array(repeating: CGFloat(0.04), count: min(capacity, 8)) : Array(visibleSamples)
			let startX = size.width - CGFloat(values.count) * (barWidth + gap) + gap

			for (index, sample) in values.enumerated() {
				let normalized = max(sample, 0.06)
				let barHeight = max(3, normalized * size.height)
				let rect = CGRect(
					x: startX + CGFloat(index) * (barWidth + gap),
					y: (size.height - barHeight) / 2,
					width: barWidth,
					height: barHeight
				)
				context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white.opacity(0.92)))
			}
		}
		.accessibilityHidden(true)
	}
}

private struct LoadingWave: View {
	let label: String
	let width: CGFloat
	let height: CGFloat

	var body: some View {
		HStack(spacing: 8) {
			TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
				Canvas { context, size in
					// The absolute timeline phase prevents a loader restart when the
					// underlying work transitions from transcription to refinement.
					let phase = timeline.date.timeIntervalSinceReferenceDate * 6
					let amplitude = max(2, size.height * 0.22)
					let angularFrequency = (CGFloat.pi * 2 * 1.4) / max(size.width, 1)
					var path = Path()

					for x in stride(from: CGFloat.zero, through: size.width, by: 1) {
						let y = size.height / 2 - sin(x * angularFrequency + phase) * amplitude
						if x == 0 {
							path.move(to: .init(x: x, y: y))
						} else {
							path.addLine(to: .init(x: x, y: y))
						}
					}

					context.stroke(path, with: .color(.white.opacity(0.92)), lineWidth: 1.5)
				}
			}
			.frame(width: min(width * 0.35, 44), height: height)

			Text(label)
				.font(.system(size: max(10, height * 0.38), weight: .semibold))
				.foregroundStyle(.white)
		}
		.frame(width: width + 20, height: height)
		.accessibilityHidden(true)
	}
}

// MARK: - View

struct TranscriptionIndicatorOverlayView: View {
	@Bindable var store: StoreOf<TranscriptionFeature>
	@ObserveInjection var inject
	@Shared(.hexSettings) var hexSettings: HexSettings
	let onOpenHistory: () -> Void
	let onPillSizeChange: (CGSize?) -> Void
	@State private var currentPillSize: CGSize?

	var status: TranscriptionIndicatorView.Status {
		if let presentation = store.completedTranscriptPresentation {
			switch presentation {
			case let .expanded(text): return .completedTranscript(text)
			case let .copied(text): return .copied(text)
			case let .hidingCopied(text): return .hidingCopied(text)
			}
		} else if let error = store.error {
			return .error(error)
		} else if store.isScreenAwareModeActive {
			return .screenAware
		} else if store.isRefining || (store.isTranscribing && store.forcedRefinementMode != nil) {
			return .refining
		} else if store.isTranscribing {
			return .transcribing
		} else if store.isRecording {
			return .recording
		} else if store.isPrewarming {
			return .prewarming
		} else {
			return .hidden
		}
	}

	var body: some View {
		let indicatorStatus = status
		TranscriptionIndicatorView(
			status: indicatorStatus,
			meter: indicatorStatus.showsWaveform ? store.meter : .init(averagePower: 0, peakPower: 0),
			size: hexSettings.indicatorSize,
			onOpenHistory: onOpenHistory,
			onCopyCompletedTranscript: { store.send(.copyCompletedTranscript) },
			onDismissCompletedTranscript: { store.send(.dismissCompletedTranscript) },
			onCardSizeChange: { size in
				currentPillSize = size
				onPillSizeChange(size)
			}
		)
		.animation(.snappy(duration: 0.22), value: indicatorStatus)
		.animation(.snappy(duration: 0.22), value: hexSettings.indicatorSize)
		.onChange(of: hexSettings.indicatorLocation) { _, _ in
			onPillSizeChange(currentPillSize)
		}
		.onDisappear { onPillSizeChange(nil) }
		.task {
			await store.send(.task).finish()
		}
		.enableInjection()
	}
}

#Preview("Transcription Indicator") {
	VStack(spacing: 16) {
		TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.5, peakPower: 0.75), size: .regular)
		TranscriptionIndicatorView(status: .screenAware, meter: .init(averagePower: 0.5, peakPower: 0.75), size: .regular)
		TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0), size: .regular)
	}
	.padding(40)
	.background(.black)
}
