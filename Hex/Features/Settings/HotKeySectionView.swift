import ComposableArchitecture
import HexCore
import Inject
import SwiftUI

struct HotKeySectionView: View {
    @ObserveInjection var inject
    @Bindable var store: StoreOf<SettingsFeature>

    var body: some View {
        Section("Hot Key") {
            let hotKey = store.hexSettings.hotkey
            let key = store.isSettingHotKey ? nil : hotKey.key
            let modifiers = store.isSettingHotKey ? store.currentModifiers : hotKey.modifiers

            VStack(spacing: 12) {
                // Hot key view
                HStack {
                    Spacer()
                    HotKeyView(modifiers: modifiers, key: key, isActive: store.isSettingHotKey)
                        .animation(.spring(), value: key)
                        .animation(.spring(), value: modifiers)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.send(.startSettingHotKey)
                }

                if !store.isSettingHotKey,
                   hotKey.key == nil,
                   !hotKey.modifiers.isEmpty {
                    ModifierSideControls(
                        modifiers: hotKey.modifiers,
                        onSelect: { kind, side in
                            store.send(.setModifierSide(kind, side))
                        }
                    )
                    .transition(.opacity)
                }
            }

            Label {
                Toggle(
                    "Enable double-tap lock",
                    isOn: Binding(
                        get: { store.hexSettings.doubleTapLockEnabled },
                        set: { store.send(.setDoubleTapLockEnabled($0)) }
                    )
                )
            } icon: {
                Image(systemName: "hand.tap")
            }

            if store.hexSettings.doubleTapLockEnabled {
                Label {
                    Toggle(
                        "Use double-tap only",
                        isOn: Binding(
                            get: { store.hexSettings.useDoubleTapOnly },
                            set: { store.send(.setUseDoubleTapOnly($0)) }
                        )
                    )
                } icon: {
                    Image(systemName: "hand.tap.fill")
                }

				if store.hexSettings.useDoubleTapOnly {
					Label {
						Toggle(
							"Allow long press for on-demand",
							isOn: Binding(
								get: { store.hexSettings.allowLongPressForOnDemand },
								set: { store.send(.setAllowLongPressForOnDemand($0)) }
							)
						)
					} icon: {
						Image(systemName: "hand.raised.fill")
					}
				}
            }

            // Minimum key time (for modifier-only shortcuts)
            if store.hexSettings.hotkey.key == nil,
               !(store.hexSettings.doubleTapLockEnabled && store.hexSettings.useDoubleTapOnly) {
                Label {
                    Slider(
                        value: Binding(
                            get: { store.hexSettings.minimumKeyTime },
                            set: { store.send(.setMinimumKeyTime($0)) }
                        ),
                        in: 0.0 ... 2.0,
                        step: 0.1
                    ) {
                        Text("Ignore below \(store.hexSettings.minimumKeyTime, specifier: "%.1f")s")
                    }
                } icon: {
                    Image(systemName: "clock")
                }
            }

            LabeledContent {
                TextField(
                    "",
                    value: Binding(
                        get: { store.hexSettings.stopDelayMilliseconds },
                        set: { store.send(.setStopDelayMilliseconds($0)) }
                    ),
                    format: .number
                )
                .labelsHidden()
                .accessibilityLabel("Stop delay in milliseconds")
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stop delay in ms")
                        Text("Grace period to include audio in transcription after stop button is pressed")
                            .settingsCaption()
                    }
                } icon: {
                    Image(systemName: "timer")
                }
            }

			LabeledContent {
				Stepper(
					value: Binding(
						get: { store.hexSettings.longRecordingConfirmationThresholdMinutes },
						set: { store.send(.setLongRecordingConfirmationThresholdMinutes($0)) }
					),
					in: 1 ... 60
				) {
					Text("\(store.hexSettings.longRecordingConfirmationThresholdMinutes) min")
						.monospacedDigit()
				}
				.labelsHidden()
			} label: {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text("Confirm cancelling long recordings")
						Text("Ask before Escape cancels a recording after this many minutes")
							.settingsCaption()
					}
				} icon: {
					Image(systemName: "exclamationmark.shield")
				}
			}

			if store.hexSettings.agentHandoffEnabled, hotKey.modifiers.contains(.shift) {
				Text("Agent Handoff is unavailable because this hotkey already includes Shift.")
					.settingsCaption()
			} else if store.hexSettings.agentHandoffEnabled {
				Text("Use Shift with this hotkey to end a recording as an Agent Handoff. It creates native Codex or Claude tasks instead of pasting the transcript.")
					.settingsCaption()
			}

            HStack(spacing: 16) {
                Label("Hotkey Sequences", systemImage: "command")
                    .font(.headline)

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    HotKeyPressPill(kind: .long, showsLabel: true)
                    HotKeyPressPill(kind: .short, showsLabel: true)
                }
            }
            .padding(.top, 8)

            ForEach(Array(hotKeySequences.enumerated()), id: \.offset) { _, sequence in
                LabeledContent {
                    HStack(spacing: 6) {
						ForEach(Array(sequence.presses.enumerated()), id: \.offset) { index, press in
							if index > 0, sequence.usesPlusSeparator {
								Text("+")
									.font(.caption.weight(.semibold))
									.foregroundStyle(.secondary)
							}
                            HotKeyPressPill(kind: press)
                        }
                    }
                } label: {
                    Text(sequence.title)
                }
            }
        }
        .enableInjection()
    }

    private var hotKeySequences: [HotKeySequence] {
        let refinementEnabled = store.hexSettings.refinementEnabled
		let agentHandoffEnabled = store.hexSettings.agentHandoffEnabled
        if store.hexSettings.doubleTapLockEnabled {
			return ((!store.hexSettings.useDoubleTapOnly || store.hexSettings.allowLongPressForOnDemand)
				? [HotKeySequence(title: String(localized: refinementEnabled ? "Start on-demand transcription or insta-refine selected text" : "Start on-demand transcription"), presses: [.long])]
                : []) + [
                HotKeySequence(title: String(localized: "Start hands-free transcription"), presses: [.short, .short]),
                HotKeySequence(title: String(localized: "Finish normally"), presses: [.short]),
			] + (refinementEnabled ? [
				HotKeySequence(title: String(localized: "Start screen-aware transcription"), presses: [.short, .long]),
                HotKeySequence(title: String(localized: "Finish with refinement"), presses: [.long]),
				HotKeySequence(
					title: String(localized: "Finish with rewrite prompt"),
					presses: [.numberRange, .long],
					usesPlusSeparator: true
				),
			] : []) + agentHandoffSequence(enabled: agentHandoffEnabled)
        } else {
			return [
                HotKeySequence(title: String(localized: "Transcribe while held"), presses: [.long]),
			] + (refinementEnabled ? [
                HotKeySequence(title: String(localized: "Start screen-aware transcription"), presses: [.short, .long]),
                HotKeySequence(title: String(localized: "Refine the last transcription"), presses: [.long, .short]),
			] : []) + agentHandoffSequence(enabled: agentHandoffEnabled)
        }
    }

	private func agentHandoffSequence(enabled: Bool) -> [HotKeySequence] {
		guard enabled, !store.hexSettings.hotkey.modifiers.contains(.shift) else { return [] }
		return [
			HotKeySequence(
				title: String(localized: "Finish with Agent Handoff"),
				presses: [.shift, .long],
				usesPlusSeparator: true
			),
		]
	}
}

private struct HotKeySequence {
    let title: String
    let presses: [HotKeyPressKind]
	var usesPlusSeparator = false
}

private enum HotKeyPressKind: Equatable {
    case long
	case short
	case shift
	case numberRange

    var label: String {
        switch self {
        case .long:
            String(localized: "Long")
		case .short:
			String(localized: "Short")
		case .shift:
			String(localized: "Shift")
		case .numberRange:
			String(localized: "1 through 9")
        }
    }

    var width: CGFloat {
        switch self {
        case .long:
            54
		case .short:
			28
		case .shift:
			44
		case .numberRange:
			54
        }
    }

    var labeledWidth: CGFloat {
        switch self {
        case .long:
            64
		case .short:
			44
		case .shift:
			54
		case .numberRange:
			64
        }
    }
}

private struct HotKeyPressPill: View {
    let kind: HotKeyPressKind
    var showsLabel = false

    var body: some View {
		let usesKeyboardKeyStyle = kind == .numberRange || kind == .shift
        Group {
			if case .numberRange = kind {
				HStack(spacing: 4) {
					Image(systemName: "keyboard")
					Text("1–9")
				}
				.font(.caption.weight(.medium))
				.foregroundStyle(.secondary)
			} else if case .shift = kind {
				HStack(spacing: 4) {
					Image(systemName: "keyboard")
					Text(kind.label)
				}
					.font(.caption.weight(.medium))
					.foregroundStyle(.secondary)
			} else if showsLabel {
                Text(kind.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Capsule()
                    .fill(.secondary.opacity(0.45))
            }
        }
        .frame(
            width: showsLabel || usesKeyboardKeyStyle ? kind.labeledWidth : kind.width,
            height: showsLabel || usesKeyboardKeyStyle ? 20 : 10
        )
        .background {
			if showsLabel || usesKeyboardKeyStyle {
                Capsule()
                    .fill(.secondary.opacity(0.12))
            }
        }
        .overlay {
			if showsLabel || usesKeyboardKeyStyle {
                Capsule()
                    .stroke(.secondary.opacity(0.22), lineWidth: 1)
            }
        }
        .accessibilityLabel(Text(kind.label))
    }
}

struct ModifierSideControls: View {
    @ObserveInjection var inject
    var modifiers: Modifiers
    var onSelect: (Modifier.Kind, Modifier.Side) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(modifiers.kinds, id: \.self) { kind in
                if kind.supportsSideSelection {
                    let binding = Binding<Modifier.Side>(
                        get: { modifiers.side(for: kind) ?? .either },
                        set: { onSelect(kind, $0) }
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(kind.symbol) \(kind.displayName)")
                            .settingsCaption()

                        Picker("Modifier side", selection: binding) {
                            ForEach(Modifier.Side.allCases, id: \.self) { side in
                                Text(side.displayName)
                                    .tag(side)
                                    .disabled(!kind.supportsSideSelection && side != .either)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .enableInjection()
    }
}
