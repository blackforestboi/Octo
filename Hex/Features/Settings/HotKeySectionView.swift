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
                        ForEach(Array(sequence.presses.enumerated()), id: \.offset) { _, press in
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
        if store.hexSettings.doubleTapLockEnabled {
            [
                HotKeySequence(title: String(localized: "Start on-demand transcription"), presses: [.long]),
                HotKeySequence(title: String(localized: "Start hands-free transcription"), presses: [.short, .short]),
                HotKeySequence(title: String(localized: "Start screen-aware transcription"), presses: [.short, .long]),
                HotKeySequence(title: String(localized: "Finish normally"), presses: [.short]),
                HotKeySequence(title: String(localized: "Finish with refinement"), presses: [.long]),
            ]
        } else {
            [
                HotKeySequence(title: String(localized: "Transcribe while held"), presses: [.long]),
                HotKeySequence(title: String(localized: "Start screen-aware transcription"), presses: [.short, .long]),
                HotKeySequence(title: String(localized: "Refine the last transcription"), presses: [.long, .short]),
            ]
        }
    }
}

private struct HotKeySequence {
    let title: String
    let presses: [HotKeyPressKind]
}

private enum HotKeyPressKind {
    case long
    case short

    var label: String {
        switch self {
        case .long:
            String(localized: "Long")
        case .short:
            String(localized: "Short")
        }
    }

    var width: CGFloat {
        switch self {
        case .long:
            54
        case .short:
            28
        }
    }

    var labeledWidth: CGFloat {
        switch self {
        case .long:
            64
        case .short:
            44
        }
    }
}

private struct HotKeyPressPill: View {
    let kind: HotKeyPressKind
    var showsLabel = false

    var body: some View {
        Group {
            if showsLabel {
                Text(kind.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Capsule()
                    .fill(.secondary.opacity(0.45))
            }
        }
        .frame(
            width: showsLabel ? kind.labeledWidth : kind.width,
            height: showsLabel ? 20 : 10
        )
        .background {
            if showsLabel {
                Capsule()
                    .fill(.secondary.opacity(0.12))
            }
        }
        .overlay {
            if showsLabel {
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
