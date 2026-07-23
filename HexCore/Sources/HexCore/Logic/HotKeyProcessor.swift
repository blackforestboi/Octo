//
//  HotKeyProcessor.swift
//  Hex
//
//  Created by Kit Langton on 1/28/25.
//
import Dependencies
import Foundation
import SwiftUI

private let hotKeyLogger = HexLog.hotKey

/// A state machine that processes keyboard events to detect hotkey activations.
///
/// Implements two complementary recording modes:
/// 1. **Press-and-Hold**: Start recording when hotkey is pressed, stop when released
/// 2. **Double-Tap Lock**: Quick double-tap locks recording until hotkey is pressed again
///
/// # Architecture
///
/// The processor maintains three possible states:
/// - `.idle`: Waiting for hotkey activation
/// - `.pressAndHold(startTime)`: Recording active, will stop when hotkey released
/// - `.doubleTapLock`: Recording locked, requires explicit hotkey press to stop
///
/// # Double-Tap Detection
///
/// A "tap" is a quick press-and-release sequence. The processor tracks release times:
/// - First tap: Press hotkey → release → record release time
/// - Second tap: If pressed within `doubleTapThreshold` (0.3s), enters `.doubleTapLock`
/// - The lock persists until the user presses the hotkey again or presses ESC
///
/// # Press-and-Hold Behavior
///
/// Standard recording mode:
/// - Hotkey pressed → `.startRecording` output, enter `.pressAndHold` state
/// - Hotkey released → `.stopRecording` output, return to `.idle`
/// - Different key pressed within threshold → cancel (accidental activation prevention)
/// - Different key pressed after threshold → ignored (intentional simultaneous input)
///
/// # Modifier-Only Hotkey Specifics
///
/// For hotkeys with no key component (e.g., Option-only):
/// - "Press" = all required modifiers held, no key pressed
/// - "Release" = any required modifier released
/// - Uses higher minimum duration (0.3s) to prevent conflicts with OS shortcuts
/// - Mouse clicks within threshold → silent discard (prevents Option+click conflicts)
/// - After threshold, only ESC cancels (mouse clicks ignored)
///
/// # Dirty State & Backsliding Prevention
///
/// After cancellation or with extra modifiers, processor enters "dirty" state:
/// - All input ignored until full release (key:nil, modifiers:[])
/// - Prevents accidental re-triggering during complex key combinations
/// - User cannot "backslide" into hotkey by releasing extra modifiers
///
/// # ESC Key Handling
///
/// Pressing ESC always cancels active recordings:
/// - Returns `.cancel` output (plays cancel sound)
/// - Enters dirty state to prevent immediate re-triggering
/// - Works in both `.pressAndHold` and `.doubleTapLock` states
///
/// # Example Interaction Flow
///
/// ```
/// // Simple press-and-hold (Cmd+A hotkey)
/// Event: Cmd+A pressed   → Output: .startRecording, State: .pressAndHold
/// Event: Cmd released    → Output: .stopRecording, State: .idle
///
/// // Double-tap lock (Option hotkey)
/// Event: Option pressed  → Output: .startRecording, State: .pressAndHold
/// Event: Option released → Output: .stopRecording, State: .idle
/// Event: Option pressed  → Output: .startRecording, State: .pressAndHold
/// Event: Option released → Output: nil, State: .doubleTapLock (locked!)
/// Event: Option pressed  → Output: .stopRecording, State: .idle
///
/// // Accidental trigger prevention
/// Event: Cmd+A pressed         → Output: .startRecording, State: .pressAndHold
/// Event: Cmd+B pressed (0.1s)  → Output: .stopRecording, State: .idle (different key)
/// ```
///
/// # Related Components
///
/// - `RecordingDecisionEngine`: Determines if recording duration meets minimum thresholds
/// - `KeyEvent`: Input events from keyboard monitoring
/// - `HotKey`: Configuration of which key/modifiers to detect
///
public struct HotKeyProcessor {
    @Dependency(\.date.now) var now

    // MARK: - Configuration
    
    /// The hotkey combination to detect (key + modifiers)
    public var hotkey: HotKey
    
    /// If true, quick taps only activate recording as a double-tap lock.
    /// A held first press still activates an ordinary press-and-hold recording.
    public var useDoubleTapOnly: Bool = false

    /// When set, a second press that would establish a double-tap lock remains
    /// held long enough to measure this duration before it enters the locked state.
    public var lockingHoldDuration: TimeInterval?

    /// Whether the current lock was entered after the second tap was held for
    /// at least `lockingHoldDuration`.
    public private(set) var isLongPressLocked: Bool = false

    /// Whether the current hold is the second press that will establish a
    /// double-tap lock when released.
    public var isLockingHold: Bool {
        secondTapHoldPendingRelease
    }

    /// Enables the quick-tap, then held-second-tap screen-aware gesture while
    /// ordinary press-and-hold recording is active.
    public var screenAwareSecondTapEnabled: Bool = false

    /// Enables the long-hold, then quick-second-tap refinement gesture for
    /// press-and-hold recording. The second tap is consumed as a refinement
    /// request rather than beginning a new recording.
    public var postHoldRefinementEnabled: Bool = false

    /// If false, the quick double-tap lock gesture is disabled.
    /// Press-and-hold still works normally.
    public var doubleTapLockEnabled: Bool = true
    
    /// Minimum duration before very quick taps are considered valid
    /// For modifier-only hotkeys, this is overridden to 0.3s minimum
    public var minimumKeyTime: TimeInterval = 0.15

    // MARK: - State
    
    /// Current state of the processor
    public private(set) var state: State = .idle
    
    /// Timestamp of the most recent hotkey release (for double-tap detection)
    private var lastTapAt: Date?

    /// The second tap has started recording and is being measured for either a
    /// screen-aware hold or a double-tap lock.
    private var secondTapHoldPendingRelease = false

    /// Whether the most recently completed press-and-hold gesture was long
    /// enough to be followed by the quick-tap refinement gesture.
    private var lastTapWasLong = false
    
    /// When true, all input is ignored until full keyboard release
    /// Prevents accidental re-triggering after cancellation or during complex key combos
    private var isDirty: Bool = false

    // MARK: - Timing Thresholds
    
    /// Maximum time between two taps to be considered a double-tap (0.3 seconds)
    /// Chosen to feel responsive while avoiding accidental double-taps
    public static let doubleTapThreshold: TimeInterval = HexCoreConstants.doubleTapWindow
    
    /// Time window for canceling press-and-hold on different key press (1 second)
    /// For key+modifier hotkeys: different key within 1s = accidental, after 1s = intentional
    public static let pressAndHoldCancelThreshold: TimeInterval = HexCoreConstants.pressAndHoldCancelWindow

    // MARK: - Initialization
    
    /// Creates a new hotkey processor
    /// - Parameters:
    ///   - hotkey: The key combination to detect
    ///   - useDoubleTapOnly: If true, quick taps require a double-tap lock while holds still record
    ///   - doubleTapLockEnabled: If false, disables double-tap lock behavior
    ///   - minimumKeyTime: Minimum duration for valid key press (overridden to modifierOnlyMinimumDuration for modifier-only)
    public init(
        hotkey: HotKey,
        useDoubleTapOnly: Bool = false,
        doubleTapLockEnabled: Bool = true,
        minimumKeyTime: TimeInterval = HexCoreConstants.defaultMinimumKeyTime
    ) {
        self.hotkey = hotkey
        self.useDoubleTapOnly = useDoubleTapOnly
        self.doubleTapLockEnabled = doubleTapLockEnabled
        self.minimumKeyTime = minimumKeyTime
    }

    // MARK: - Public API
    
    /// Returns true if recording is currently active (press-and-hold or double-tap locked)
    public var isMatched: Bool {
        switch state {
        case .idle, .pendingPressAndHold:
            return false
        case .pressAndHold, .doubleTapLock, .endingHold:
            return true
        }
    }

    /// Stops tracking the current activation without emitting a recording action.
    ///
    /// This is used when another hotkey takes over ending a recording, so a
    /// double-tap-locked processor cannot keep intercepting subsequent input.
    public mutating func reset() {
        isDirty = false
        resetToIdle()
    }

	/// Returns whether the active press-and-hold gesture has reached a duration.
	/// Double-tap-locked sessions deliberately return false.
	public func hasBeenHeld(for minimumDuration: TimeInterval) -> Bool {
		guard case let .pressAndHold(startTime) = state else { return false }
		return now.timeIntervalSince(startTime) >= minimumDuration
	}

    /// Processes a keyboard event and returns an action to take, if any.
    ///
    /// - Parameter keyEvent: The keyboard event containing key and modifier state
    /// - Returns: An output action (.startRecording, .stopRecording, .cancel, .discard) or nil if no action needed
    ///
    /// # Event Processing Order
    /// 1. ESC key → immediate cancellation
    /// 2. Dirty state check → ignore input until full release
    /// 3. Matching chord → handle as hotkey press
    /// 4. Non-matching chord → handle as release or different key
    public mutating func process(keyEvent: KeyEvent) -> Output? {
        // 1) ESC => immediate cancel
        if keyEvent.key == .escape {
            let currentState = state
            hotKeyLogger.notice("ESC pressed while state=\(String(describing: currentState))")
        }
        if keyEvent.key == .escape, state != .idle {
            isDirty = true
            resetToIdle()
            return .cancel
        }

        // 2) If dirty, ignore until full release (nil, [])
        if isDirty {
            if chordIsFullyReleased(keyEvent) {
                isDirty = false
            } else {
                return nil
            }
        }

        // 3) Matching chord => handle as "press"
        if chordMatchesHotkey(keyEvent) {
            return handleMatchingChord()
        } else {
            // Potentially become dirty if chord has extra mods or different key
            if chordIsDirty(keyEvent) {
                isDirty = true
                if isDoubleTapOnlyEnabledForCurrentHotkey {
                    clearDoubleTapTracking()
                }
            }
            return handleNonmatchingChord(keyEvent)
        }
    }

    /// Processes a mouse click event to prevent accidental recordings.
    ///
    /// For modifier-only hotkeys, mouse clicks can interfere with recording:
    /// - Option+click = duplicate items in Finder
    /// - Cmd+click = open in new tab
    /// - etc.
    ///
    /// This method discards recordings that haven't passed the minimum threshold yet.
    ///
    /// - Returns: `.discard` if recording canceled, nil if click ignored
    ///
    /// # Behavior
    /// - Modifier-only hotkeys: Discard if within threshold, ignore after threshold
    /// - Key+modifier hotkeys: Always ignore (no conflict with mouse clicks)
    /// - Double-tap lock: Always ignore (intentional recording, only ESC cancels)
    public mutating func processMouseClick() -> Output? {
        // Only cancel if:
        // 1. The hotkey is modifier-only (no key component)
        // 2. We're currently in an active recording state (pressAndHold or doubleTapLock)
        guard hotkey.key == nil else {
            return nil
        }

        switch state {
        case .idle:
            return nil
        case let .pendingPressAndHold(startTime):
            let elapsed = now.timeIntervalSince(startTime)
            guard elapsed >= Self.doubleTapThreshold else {
                resetToIdle()
                return .cancelPendingPressAndHold
            }
            // The delayed activation has fired. Adopt the normal hold state so
            // mouse behavior matches every other press-and-hold recording.
            state = .pressAndHold(startTime: startTime)
            let effectiveMinimum = max(minimumKeyTime, RecordingDecisionEngine.modifierOnlyMinimumDuration)
            if elapsed < effectiveMinimum {
                isDirty = true
                resetToIdle()
                return .discard
            }
            return nil
        case let .pressAndHold(startTime):
            // Mouse click during modifier-only recording
            let elapsed = now.timeIntervalSince(startTime)
            // For modifier-only hotkeys, use the same threshold as RecordingDecisionEngine
            // (max of minimumKeyTime and 0.3s) to be consistent
            let effectiveMinimum = max(minimumKeyTime, RecordingDecisionEngine.modifierOnlyMinimumDuration)
            
            // Only discard if within threshold - after threshold, ignore clicks (only ESC cancels)
            if elapsed < effectiveMinimum {
                isDirty = true
                resetToIdle()
                return .discard
            } else {
                // After threshold, ignore mouse clicks - let recording continue
                return nil
            }
        case .doubleTapLock, .endingHold:
            // Mouse click during double-tap lock => ignore (only ESC cancels locked recordings)
            return nil
        }
    }
}

// MARK: - State & Output

public extension HotKeyProcessor {
    /// Represents the current state of hotkey detection
    enum State: Equatable {
        /// Idle, waiting for hotkey activation
        case idle

        /// The first press in double-tap-only mode is waiting to cross the
        /// hold threshold before recording starts.
        case pendingPressAndHold(startTime: Date)
        
        /// Press-and-hold recording active
        /// - Parameter startTime: When the hotkey was first pressed (for duration calculation)
        case pressAndHold(startTime: Date)
        
        /// Double-tap lock active - recording continues until explicit stop
        case doubleTapLock

        /// A locked recording is waiting for the terminal hotkey release so its
        /// duration can choose normal transcription or refinement.
        case endingHold(startTime: Date)
    }

    /// Actions to take in response to keyboard events
    enum Output: Equatable {
        /// Begin a new recording session
        case startRecording

		/// Begin recording and arm the screen-aware second-tap hold threshold.
		case startRecordingAndArmScreenAware

        /// Schedule a press-and-hold recording if the first press remains held.
        case armPendingPressAndHold

        /// Cancel a scheduled hold because the first press was released quickly.
        case cancelPendingPressAndHold

        /// Schedule refinement for a locked recording once its terminal activation
        /// reaches the configured hold duration, without waiting for key-up.
        case armTerminalRefinement
        
        /// Stop the current recording and process audio
        case stopRecording

        /// Stop the current recording and run the downstream refinement stage.
        case stopRecordingWithRefinement

        /// Stop the current recording after capturing screen context. This is
        /// the non-locking variant of the held-second-tap gesture.
        case stopRecordingWithScreenContext

        /// Refine the most recently completed transcription. This handles a
        /// quick terminal tap that arrives after a press-and-hold recording has
        /// already finished transcribing and pasted its baseline result.
        case refineMostRecentTranscription

        /// Recording remains active after a second tap established a double-tap lock.
        /// The associated hold duration can be inspected with `isLongPressLocked`.
        case locked
        
        /// Explicit user cancellation via ESC key
        /// Plays cancel sound to provide feedback
        case cancel
        
        /// Silent discard of accidental/short activation
        /// Used for very quick taps or mouse click conflicts
        case discard
    }
}

// MARK: - Core Logic

extension HotKeyProcessor {
    private var isDoubleTapOnlyEnabledForCurrentHotkey: Bool {
        useDoubleTapOnly && doubleTapLockEnabled
    }

    /// Handles keyboard events that match the configured hotkey.
    ///
    /// # State Transitions
    /// - `.idle` → `.pressAndHold`: Start a new recording
    /// - `.idle` → `.pendingPressAndHold`: Wait to distinguish a tap from a hold
    /// - `.pressAndHold` → no change: Already recording, ignore
        /// - `.doubleTapLock` → `.endingHold`: User pressed hotkey to end locked recording
    ///
    /// # Double-Tap Only Mode
    /// When useDoubleTapOnly is enabled:
    /// - First press: Arm a delayed press-and-hold recording
    /// - Quick first release: Cancel the delay and arm the double-tap lock
    /// - Held first press: Start an ordinary press-and-hold recording after the threshold
    /// - Second press within threshold: Start recording, then enter the lock on release
    ///
    /// - Returns: `.startRecording` when entering press-and-hold, `.stopRecording` when exiting lock
    private mutating func handleMatchingChord() -> Output? {
        switch state {
        case .idle:
            if postHoldRefinementEnabled,
               lastTapWasLong,
               let prevTapTime = lastTapAt,
               now.timeIntervalSince(prevTapTime) < Self.doubleTapThreshold
            {
                clearDoubleTapTracking()
                return .refineMostRecentTranscription
            }

            if isDoubleTapOnlyEnabledForCurrentHotkey {
                if let prevTapTime = lastTapAt,
                   now.timeIntervalSince(prevTapTime) < Self.doubleTapThreshold {
                    clearDoubleTapTracking()
                    if lockingHoldDuration != nil {
                        state = .pressAndHold(startTime: now)
                        secondTapHoldPendingRelease = true
                    } else {
                        state = .doubleTapLock
                    }
                    isLongPressLocked = false
					return screenAwareSecondTapEnabled
						? .startRecordingAndArmScreenAware
						: .startRecording
                } else {
                    lastTapAt = nil
                    state = .pendingPressAndHold(startTime: now)
                    return .armPendingPressAndHold
                }
            } else {
                // Normal press => .pressAndHold => .startRecording
                state = .pressAndHold(startTime: now)
                if (doubleTapLockEnabled || screenAwareSecondTapEnabled),
                   lockingHoldDuration != nil,
                   let prevTapTime = lastTapAt,
                   now.timeIntervalSince(prevTapTime) < Self.doubleTapThreshold
                {
                    // Remember that this is the second press at key-down. The release
                    // may arrive outside the double-tap window when the user holds it
                    // for Screen Aware, but it must still establish the lock. When
                    // Screen Aware is unavailable the same gesture safely falls back
                    // to an ordinary lock.
                    secondTapHoldPendingRelease = true
                }
				return secondTapHoldPendingRelease && screenAwareSecondTapEnabled
					? .startRecordingAndArmScreenAware
					: .startRecording
            }

        case .pressAndHold:
            // Already matched, no new output
            return nil

        case .pendingPressAndHold:
            // Repeated events while the first press remains held do not re-arm it.
            return nil

        case .doubleTapLock:
            // Arm a threshold effect immediately. A quick release still chooses normal
            // completion, while crossing the threshold can refine before key-up.
            state = .endingHold(startTime: now)
            return lockingHoldDuration == nil ? nil : .armTerminalRefinement

        case .endingHold:
            return nil
        }
    }

    /// Handles keyboard events that don't match the configured hotkey.
    ///
    /// This method detects:
    /// 1. **Hotkey release**: User lifted the hotkey (transition to idle or double-tap lock)
    /// 2. **Different key press**: User pressed a different key while holding hotkey (potential cancel)
    /// 3. **Extra modifiers**: User added modifiers beyond hotkey requirements (potential cancel)
    ///
    /// # Cancel Behavior
    /// Different keys/modifiers are handled based on timing and hotkey type:
    ///
    /// **Modifier-only hotkeys:**
    /// - Within threshold (0.3s): Discard silently (accidental trigger, e.g., Option+click)
    /// - After threshold: Ignore completely, keep recording (only ESC cancels)
    ///
    /// **Key+modifier hotkeys:**
    /// - Within 1s: Stop recording (likely accidental)
    /// - After 1s: Ignore, keep recording (intentional simultaneous input)
    ///
    /// - Parameter e: The non-matching keyboard event
    /// - Returns: Recording control output or nil
    private mutating func handleNonmatchingChord(_ e: KeyEvent) -> Output? {
        switch state {
        case .idle:
            return nil

        case let .pendingPressAndHold(startTime):
            let elapsed = now.timeIntervalSince(startTime)
            guard isReleaseForActiveHotkey(e) else {
                if elapsed >= Self.doubleTapThreshold {
                    // The delayed activation has fired; from this event onward,
                    // use the ordinary press-and-hold conflict behavior.
                    state = .pressAndHold(startTime: startTime)
                    return handleNonmatchingChord(e)
                }
                resetToIdle()
                return .cancelPendingPressAndHold
            }

            let wasQuickTap = elapsed < Self.doubleTapThreshold
            state = .idle
            secondTapHoldPendingRelease = false
            lastTapWasLong = false
            isLongPressLocked = false
            if wasQuickTap {
                lastTapAt = now
                return .cancelPendingPressAndHold
            }

            lastTapAt = nil
            return .stopRecording

        case let .pressAndHold(startTime):
            // If user truly "released" the chord => either normal stop or doubleTapLock
            if isReleaseForActiveHotkey(e) {
                if secondTapHoldPendingRelease {
                    let wasLongSecondTap = lockingHoldDuration.map {
                        now.timeIntervalSince(startTime) >= $0
                    } ?? false
                    clearDoubleTapTracking()
                    if doubleTapLockEnabled {
                        state = .doubleTapLock
                        isLongPressLocked = wasLongSecondTap
                        return .locked
                    }

                    state = .idle
                    return wasLongSecondTap ? .stopRecordingWithScreenContext : .stopRecording
                }

                // Check if this release is close to the prior release => double-tap lock
                if doubleTapLockEnabled,
                   let prevReleaseTime = lastTapAt,
                   now.timeIntervalSince(prevReleaseTime) < Self.doubleTapThreshold
                {
                    // => Switch to doubleTapLock, remain matched, no new output
                    state = .doubleTapLock
                    isLongPressLocked = false
                    return nil
                } else {
                    // Normal stop => idle => record the release time
                    state = .idle
                    lastTapAt = (doubleTapLockEnabled || screenAwareSecondTapEnabled || postHoldRefinementEnabled) ? now : nil
                    lastTapWasLong = lockingHoldDuration.map {
                        now.timeIntervalSince(startTime) >= $0
                    } ?? false
                    return .stopRecording
                }
            } else {
                // User pressed a different key/modifier while holding hotkey
                let elapsed = now.timeIntervalSince(startTime)
                
                // Modifier-only hotkeys: Only discard within threshold, ignore after
                if hotkey.key == nil {
                    let effectiveMinimum = max(minimumKeyTime, RecordingDecisionEngine.modifierOnlyMinimumDuration)
                    
                    if elapsed < effectiveMinimum {
                        // Within threshold => discard silently (accidental trigger)
                        isDirty = true
                        resetToIdle()
                        return .discard
                    } else {
                        // After threshold => ignore extra modifiers/keys, keep recording (only ESC cancels)
                        return nil
                    }
                } else {
                    // Printable-key hotkeys: Use old behavior with 1s threshold
                    if elapsed < Self.pressAndHoldCancelThreshold {
                        // Within 1s threshold => treat as accidental
                        isDirty = true
                        resetToIdle()
                        // If very quick (< minimumKeyTime), discard silently. Otherwise stop with sound.
                        return elapsed < minimumKeyTime ? .discard : .stopRecording
                    } else {
                        // After 1s => remain matched
                        return nil
                    }
                }
            }

        case .doubleTapLock:
            // If locked, ignore everything except chord == hotkey => stop.
            return nil

        case let .endingHold(startTime):
            guard isReleaseForActiveHotkey(e) else { return nil }
            let shouldRefine = lockingHoldDuration.map {
                now.timeIntervalSince(startTime) >= $0
            } ?? false
            resetToIdle()
            return shouldRefine ? .stopRecordingWithRefinement : .stopRecording
        }
    }

    // MARK: - Helpers

    /// Checks if the given keyboard event exactly matches the configured hotkey.
    ///
    /// # Matching Rules
    /// - **Key+modifier hotkey**: Both key and modifiers must match exactly
    /// - **Modifier-only hotkey**: Modifiers match exactly and no key is pressed
    ///
    /// - Parameter e: The keyboard event to check
    /// - Returns: True if event matches hotkey configuration
    private func chordMatchesHotkey(_ e: KeyEvent) -> Bool {
        if hotkey.key != nil {
            return e.key == hotkey.key && e.modifiers.matchesExactly(hotkey.modifiers)
        } else {
            return e.key == nil && e.modifiers.matchesExactly(hotkey.modifiers)
        }
    }

    /// Checks if keyboard event contains extra keys/modifiers that should trigger dirty state.
    ///
    /// "Dirty" means the user is doing something unrelated to our hotkey, so we should
    /// ignore all input until they fully release the keyboard.
    ///
    /// # Dirty Conditions
    /// - **Modifier-only hotkey**: Any key press OR extra modifiers beyond requirements
    /// - **Key+modifier hotkey**: Different key OR modifiers not subset of requirements
    ///
    /// - Parameter e: The keyboard event to check
    /// - Returns: True if event should trigger dirty state
    private func chordIsDirty(_ e: KeyEvent) -> Bool {
        if hotkey.key == nil {
            // Any key press while watching pure-modifier hotkey is "dirty"
            // Also dirty if there are extra modifiers beyond what the hotkey requires
            return e.key != nil || !e.modifiers.isSubset(of: hotkey.modifiers)
        }
        let isSubset = e.modifiers.isSubset(of: hotkey.modifiers)
        let isWrongKey = (e.key != nil && e.key != hotkey.key)
        return !isSubset || isWrongKey
    }

    /// Checks if all keys and modifiers have been released.
    ///
    /// Used to clear dirty state - once user fully releases keyboard,
    /// we can start accepting hotkey input again.
    ///
    /// - Parameter e: The keyboard event to check
    /// - Returns: True if no keys or modifiers are pressed
    private func chordIsFullyReleased(_ e: KeyEvent) -> Bool {
        e.key == nil && e.modifiers.isEmpty
    }

    /// Detects if user has released the active hotkey.
    ///
    /// Release detection differs based on hotkey type:
    ///
    /// # Key+Modifier Hotkey (e.g., Cmd+A)
    /// "Release" = key is lifted, modifiers may still be held
    /// - Allows partial modifier release before key release
    /// - User can lift Cmd slightly early without affecting detection
    ///
    /// # Modifier-Only Hotkey (e.g., Option)
    /// "Release" = required modifiers no longer pressed
    /// - Detects when user lifts the specific modifier(s)
    /// - Key must be nil (no key component in hotkey)
    ///
    /// - Parameter e: The keyboard event to check
    /// - Returns: True if hotkey has been released
    private func isReleaseForActiveHotkey(_ e: KeyEvent) -> Bool {
        if hotkey.key != nil {
            let requiredModifiers = hotkey.modifiers
            let keyReleased = e.key == nil
            let modifiersAreSubset = e.modifiers.isSubset(of: requiredModifiers)

            if keyReleased {
                // Treat as release even if some modifiers were lifted first,
                // as long as no new modifiers are introduced.
                return modifiersAreSubset
            }

            return false
        } else {
            // For modifier-only hotkeys, we check:
            // 1. Key is nil
            // 2. Required hotkey modifiers are no longer pressed
            // This detects when user has released the specific modifiers in the hotkey
            return e.key == nil && !hotkey.modifiers.isSubset(of: e.modifiers)
        }
    }

    /// Resets processor to idle state, clearing active recording state.
    ///
    /// Preserves `isDirty` flag if caller has set it, allowing dirty state
    /// to persist across state transitions for proper input blocking.
    ///
    /// Clears:
    /// - `state` → `.idle`
    /// - `lastTapAt` → nil (double-tap timing reset)
    private mutating func resetToIdle() {
        state = .idle
        isLongPressLocked = false
        clearDoubleTapTracking()
    }

    private mutating func clearDoubleTapTracking() {
        lastTapAt = nil
        secondTapHoldPendingRelease = false
        lastTapWasLong = false
    }
}
