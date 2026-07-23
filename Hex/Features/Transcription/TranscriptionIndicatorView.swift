//
//  HexCapsuleView.swift
//  Hex
//
//  Created by Kit Langton on 1/25/25.

import AppKit
import Inject
import Pow
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
	case error(String)
  }

  var status: Status
  var meter: Meter

  let transcribeBaseColor: Color = .blue
  private var backgroundColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording:
      return mixedColor(mixedNSColor(.red, with: .black, by: 0.5), with: .red, by: meter.averagePower * 3)
	case .screenAware: return mixedColor(.systemTeal, with: .black, by: 0.45)
    case .transcribing: return mixedColor(.blue, with: .black, by: 0.5)
	case .refining: return mixedColor(.purple, with: .black, by: 0.5)
    case .prewarming: return mixedColor(.blue, with: .black, by: 0.5)
	case .error: return mixedColor(.systemRed, with: .black, by: 0.4)
    }
  }

  private var strokeColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording: return mixedColor(.red, with: .white, by: 0.1).opacity(0.6)
	case .screenAware: return mixedColor(.systemTeal, with: .white, by: 0.2).opacity(0.8)
    case .transcribing: return mixedColor(.blue, with: .white, by: 0.1).opacity(0.6)
	case .refining: return mixedColor(.purple, with: .white, by: 0.1).opacity(0.6)
    case .prewarming: return mixedColor(.blue, with: .white, by: 0.1).opacity(0.6)
	case .error: return mixedColor(.systemRed, with: .white, by: 0.2).opacity(0.8)
    }
  }

  private func mixedColor(_ color: NSColor, with otherColor: NSColor, by fraction: Double) -> Color {
    Color(nsColor: mixedNSColor(color, with: otherColor, by: fraction))
  }

  private func mixedNSColor(_ color: NSColor, with otherColor: NSColor, by fraction: Double) -> NSColor {
    let clampedFraction = min(max(fraction, 0), 1)
    return color.blended(withFraction: clampedFraction, of: otherColor) ?? color
  }

  private var innerShadowColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.clear
    case .recording: return Color.red
	case .screenAware: return Color(nsColor: .systemTeal)
    case .transcribing: return transcribeBaseColor
	case .refining: return .purple
    case .prewarming: return transcribeBaseColor
	case .error: return .red
    }
  }

  private let cornerRadius: CGFloat = 8
  private let baseWidth: CGFloat = 16
  private let expandedWidth: CGFloat = 56
	private let screenAwareWidth: CGFloat = 104

	private var indicatorWidth: CGFloat {
		switch status {
		case .screenAware: screenAwareWidth
		case .recording: expandedWidth
		case .error: 300
		default: baseWidth
		}
	}

	private var accessibilityLabel: String {
		switch status {
		case .hidden: "Dictation inactive"
		case .optionKeyPressed: "Dictation hotkey pressed"
		case .recording: "Recording"
		case .screenAware: "Screen aware mode active"
		case .transcribing: "Transcribing"
		case .refining: "Refining"
		case .prewarming: "Model prewarming"
		case let .error(message): "Error: \(message)"
		}
	}

  var isHidden: Bool {
    status == .hidden
  }

  @State var transcribeEffect = 0

  var body: some View {
    let averagePower = min(1, meter.averagePower * 3)
    let peakPower = min(1, meter.peakPower * 3)
    ZStack {
      Capsule()
        .fill(backgroundColor.shadow(.inner(color: innerShadowColor, radius: 4)))
        .overlay {
          Capsule()
            .stroke(strokeColor, lineWidth: 1)
            .blendMode(.screen)
        }
        .overlay(alignment: .center) {
          RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.red.opacity(status == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 1) : 0))
            .blur(radius: 2)
            .blendMode(.screen)
            .padding(6)
        }
        .overlay(alignment: .center) {
          RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(status == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 0.5) : 0))
            .blur(radius: 1)
            .blendMode(.screen)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(7)
        }
        .overlay(alignment: .center) {
          GeometryReader { proxy in
            RoundedRectangle(cornerRadius: cornerRadius)
              .fill(Color.red.opacity(status == .recording ? (peakPower < 0.1 ? (peakPower / 0.1) * 0.5 : 0.5) : 0))
              .frame(width: max(proxy.size.width * (peakPower + 0.6), 0), height: proxy.size.height, alignment: .center)
              .frame(maxWidth: .infinity, alignment: .center)
              .blur(radius: 4)
              .blendMode(.screen)
          }.padding(6)
        }
		.overlay {
		  if status == .screenAware {
			Label("Screen aware", systemImage: "rectangle.and.text.magnifyingglass")
			  .font(.system(size: 9, weight: .semibold))
			  .foregroundStyle(.white)
			  .lineLimit(1)
		  }
		}
		.overlay {
			if case let .error(message) = status {
				Label(message, systemImage: "exclamationmark.triangle.fill")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(.white)
					.lineLimit(2)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 10)
			}
		}
        .cornerRadius(cornerRadius)
        .shadow(
          color: status == .recording ? .red.opacity(averagePower) : .red.opacity(0),
          radius: 4
        )
        .shadow(
          color: status == .recording ? .red.opacity(averagePower * 0.5) : .red.opacity(0),
          radius: 8
        )
        .animation(.interactiveSpring(), value: meter)
        .frame(
		  width: indicatorWidth,
          height: baseWidth
        )
        .opacity(status == .hidden ? 0 : 1)
        .scaleEffect(status == .hidden ? 0.0 : 1)
        .blur(radius: status == .hidden ? 4 : 0)
        .animation(.bouncy(duration: 0.3), value: status)
		.changeEffect(
		  .glow(
			color: (status == .screenAware ? innerShadowColor : .red).opacity(0.5),
			radius: 8
		  ),
		  value: status
		)
        .changeEffect(.shine(angle: .degrees(0), duration: 0.6), value: transcribeEffect)
		.compositingGroup()
		.accessibilityLabel(accessibilityLabel)
		.accessibilityHidden(status == .hidden)
		.task(id: status == .transcribing || status == .refining) {
		  while (status == .transcribing || status == .refining), !Task.isCancelled {
            transcribeEffect += 1
            try? await Task.sleep(for: .seconds(0.25))
          }
        }
      
	  // Show tooltip when prewarming or refining
	  if status == .prewarming || status == .refining {
        VStack(spacing: 4) {
		  Text(status == .refining ? "Refining..." : "Model prewarming...")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.8))
            )
        }
        .offset(y: -24)
        .transition(.opacity)
        .zIndex(2)
      }
    }
    .enableInjection()
  }
}

#Preview("HEX") {
  VStack(spacing: 8) {
    TranscriptionIndicatorView(status: .hidden, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .optionKeyPressed, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.5, peakPower: 0.5))
	TranscriptionIndicatorView(status: .screenAware, meter: .init(averagePower: 0.5, peakPower: 0.5))
    TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0))
	TranscriptionIndicatorView(status: .refining, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .prewarming, meter: .init(averagePower: 0, peakPower: 0))
  }
  .padding(40)
}
