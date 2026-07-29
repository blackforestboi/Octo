//
//  KeyEvent.swift
//  HexCore
//
//  Created by Kit Langton on 1/28/25.
//

import Sauce

public enum InputEvent {
    case keyboard(KeyEvent)
    case mouseClick
}

public enum KeyEventPhase: Sendable {
    case keyDown
    case keyUp
    case other
}

public struct KeyEvent {
    /// The key exposed to the legacy hotkey state machine. Key-up events remain
    /// `nil` so release detection keeps its existing semantics.
    public let key: Key?
    public let modifiers: Modifiers
    /// The physical key for both down and up events, when the event represents a key.
    public let physicalKey: Key?
    public let phase: KeyEventPhase

    public var isKeyDown: Bool { phase == .keyDown }
    public var isKeyUp: Bool { phase == .keyUp }
    
    public init(
        key: Key?,
        modifiers: Modifiers,
        physicalKey: Key? = nil,
        phase: KeyEventPhase? = nil
    ) {
        self.key = key
        self.modifiers = modifiers
        self.physicalKey = physicalKey ?? key
        self.phase = phase ?? (key == nil ? .other : .keyDown)
    }
}
