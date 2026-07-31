//
//  InvisibleWindow.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import AppKit
import HexCore
import SwiftUI

private final class FirstMouseHostingView: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
}

/// The transcription indicator's single overlay window. Its frame matches the
/// visible pill/card, with temporary transparent padding for the handoff comet.
class InvisibleWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private var currentScreen: NSScreen?
  private var mouseMonitor: Any?
	private var indicatorSize: CGSize?
	private var indicatorLocation: IndicatorLocation = .topCenter
	private var isAnimatingHandoffDeparture = false
	private var handoffDepartureTimer: Timer?
	private var handoffDepartureAnchor: NSPoint?

  init() {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let styleMask: NSWindow.StyleMask = [.fullSizeContentView, .borderless, .utilityWindow, .nonactivatingPanel]

    super.init(contentRect: .init(x: -2, y: -2, width: 1, height: 1),
               styleMask: styleMask,
               backing: .buffered,
               defer: false)

    currentScreen = screen
    level = .statusBar
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    ignoresMouseEvents = true
    acceptsMouseMovedEvents = true
    hidesOnDeactivate = false // Prevent hiding when app loses focus
    canHide = false
    collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]

    // Start observing screen changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenDidChange),
      name: NSWindow.didChangeScreenNotification,
      object: nil
    )

    // Also observe screen parameters for resolution changes
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenDidChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )

    // Monitor mouse movements to detect screen boundary crossings
    mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      self?.checkForScreenChange()
    }
  }

  deinit {
	  handoffDepartureTimer?.invalidate()
    NotificationCenter.default.removeObserver(self)
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }

	func update(size: CGSize?, location: IndicatorLocation, preservingCenter: Bool = false) {
		let previousCenter = NSPoint(x: frame.midX, y: frame.midY)
	handoffDepartureTimer?.invalidate()
	handoffDepartureTimer = nil
	resetHandoffMotion()
	isAnimatingHandoffDeparture = false
    let previousSize = indicatorSize
    indicatorSize = size
    indicatorLocation = location

    guard let size, size.width > 0, size.height > 0 else {
		handoffDepartureAnchor = nil
      ignoresMouseEvents = true
      setFrame(.init(x: -2, y: -2, width: 1, height: 1), display: false)
      return
    }

	alphaValue = 1
    ignoresMouseEvents = false
	if preservingCenter, previousSize != nil {
		// The handoff glow needs a larger transparent canvas, but enlarging the
		// panel through the normal location-based layout would re-anchor it to the
		// screen edge. Preserve the already-visible dot's exact center instead.
		handoffDepartureAnchor = previousCenter
		setFrame(
			NSRect(
				x: previousCenter.x - size.width / 2,
				y: previousCenter.y - size.height / 2,
				width: size.width,
				height: size.height
			),
			display: true
		)
		return
	}

	handoffDepartureAnchor = nil
    updateFrame(size: size, animated: previousSize != nil)
  }

	/// Sends the existing overlay to the center of Octo's AppKit status button.
	/// The frame is captured immediately before departure so multi-display menu
	/// bar changes are reflected in the flight path.
	func animateAgentHandoffDeparture(to statusItemFrame: NSRect?) {
		guard let screen = currentScreen ?? self.screen else {
			NotificationCenter.default.post(name: .agentHandoffArrivedAtMenuBar, object: nil)
			return
		}

		isAnimatingHandoffDeparture = true
		ignoresMouseEvents = true
		resetHandoffMotion()

		let destinationCenter = Self.agentHandoffDestination(
			statusItemFrame: statusItemFrame,
			fallbackScreenFrame: screen.frame,
			statusBarHeight: NSStatusBar.system.thickness
		)
		let startCenter = handoffDepartureAnchor ?? NSPoint(x: frame.midX, y: frame.midY)
		let departureFrame = NSRect(
			x: startCenter.x - frame.width / 2,
			y: startCenter.y - frame.height / 2,
			width: frame.width,
			height: frame.height
		)
		// Ensure the first rendered flight frame is identical to the collapsed
		// dot's last frame, even if AppKit had a pending layout transaction.
		setFrame(departureFrame, display: true)
		handoffDepartureAnchor = nil
		let destinationFrame = NSRect(
			x: destinationCenter.x - frame.width / 2,
			y: destinationCenter.y - frame.height / 2,
			width: frame.width,
			height: frame.height
		)

		let flightDuration: TimeInterval = 0.624 // 25% faster than the original 0.78s flight.
		let flightEndProgress: CGFloat = 1
		let destination = NSPoint(x: destinationFrame.midX, y: destinationFrame.midY)
		let deltaX = destination.x - startCenter.x
		let deltaY = destination.y - startCenter.y
		let distance = max(1, hypot(deltaX, deltaY))
		let curveAmount = min(72, distance * 0.15)
		let control = NSPoint(
			x: (startCenter.x + destination.x) / 2 - deltaY / distance * curveAmount,
			y: (startCenter.y + destination.y) / 2 + deltaX / distance * curveAmount
		)
		let startedAt = ProcessInfo.processInfo.systemUptime
		var previousCenter = startCenter
		var previousSampleTime = startedAt
		var smoothedBackwardDirection = CGVector.zero
		var smoothedSpeed: CGFloat = 0

		let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
			guard let self, self.isAnimatingHandoffDeparture else {
				timer.invalidate()
				return
			}

			let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
			let timeProgress = min(1, max(0, elapsed / flightDuration))
			let travelProgress = Self.easeInOut(timeProgress) * flightEndProgress
			let center = Self.quadraticBezier(
				from: startCenter,
				control: control,
				to: destination,
				progress: travelProgress
			)
			self.setFrame(
				NSRect(
					x: center.x - departureFrame.width / 2,
					y: center.y - departureFrame.height / 2,
					width: departureFrame.width,
					height: departureFrame.height
				),
				display: true
			)
			let sampleTime = ProcessInfo.processInfo.systemUptime
			let movementX = center.x - previousCenter.x
			let movementY = center.y - previousCenter.y
			let movementDistance = hypot(movementX, movementY)
			let sampleDuration = max(1.0 / 240.0, sampleTime - previousSampleTime)
			if movementDistance > 0.01 {
				let rawBackwardDirection = CGVector(
					dx: -movementX / movementDistance,
					// AppKit grows upward while SwiftUI grows downward. The backward
					// vector therefore keeps the AppKit Y sign when used by SwiftUI.
					dy: movementY / movementDistance
				)
				let response: CGFloat = 0.32
				smoothedBackwardDirection.dx += (rawBackwardDirection.dx - smoothedBackwardDirection.dx) * response
				smoothedBackwardDirection.dy += (rawBackwardDirection.dy - smoothedBackwardDirection.dy) * response
				let directionLength = max(0.001, hypot(smoothedBackwardDirection.dx, smoothedBackwardDirection.dy))
				smoothedBackwardDirection.dx /= directionLength
				smoothedBackwardDirection.dy /= directionLength
				let rawSpeed = movementDistance / CGFloat(sampleDuration)
				smoothedSpeed += (rawSpeed - smoothedSpeed) * response
				self.publishHandoffMotion(
					backwardDirection: smoothedBackwardDirection,
					speed: smoothedSpeed
				)
			}
			previousCenter = center
			previousSampleTime = sampleTime

			if timeProgress >= 1 {
				timer.invalidate()
				self.handoffDepartureTimer = nil
				NotificationCenter.default.post(name: .agentHandoffArrivedAtMenuBar, object: nil)
				NSAnimationContext.runAnimationGroup { context in
					context.duration = 0.12
					self.animator().alphaValue = 0
				}
			}
		}
		handoffDepartureTimer = timer
		RunLoop.main.add(timer, forMode: .common)
		timer.fire()
	}

	static func agentHandoffDestination(
		statusItemFrame: NSRect?,
		fallbackScreenFrame: NSRect,
		statusBarHeight: CGFloat
	) -> NSPoint {
		if let statusItemFrame,
			statusItemFrame.width > 0,
			statusItemFrame.height > 0
		{
			return NSPoint(x: statusItemFrame.midX, y: statusItemFrame.midY)
		}

		// The status item is created before the overlay, so this branch is only a
		// launch/teardown safety net. Normal handoffs always use the exact frame.
		return NSPoint(
			x: fallbackScreenFrame.maxX - 600,
			y: fallbackScreenFrame.maxY - statusBarHeight / 2
		)
	}

	private func resetHandoffMotion() {
		NotificationCenter.default.post(
			name: .agentHandoffMotionUpdated,
			object: AgentHandoffMotion.stationary
		)
	}

	private func publishHandoffMotion(backwardDirection: CGVector, speed: CGFloat) {
		NotificationCenter.default.post(
			name: .agentHandoffMotionUpdated,
			object: AgentHandoffMotion(
				backwardDirection: CGSize(width: backwardDirection.dx, height: backwardDirection.dy),
				speed: speed
			)
		)
	}

	private static func easeInOut(_ progress: CGFloat) -> CGFloat {
		if progress < 0.5 {
			return 4 * progress * progress * progress
		}
		return 1 - pow(-2 * progress + 2, 3) / 2
	}

	private static func quadraticBezier(from: NSPoint, control: NSPoint, to: NSPoint, progress: CGFloat) -> NSPoint {
		let inverse = 1 - progress
		return NSPoint(
			x: inverse * inverse * from.x + 2 * inverse * progress * control.x + progress * progress * to.x,
			y: inverse * inverse * from.y + 2 * inverse * progress * control.y + progress * progress * to.y
		)
	}

  private func updateToScreenWithMouse() {
	// Expanding the transparent comet canvas can make the panel overlap a
	// neighboring display and emit didChangeScreen before flight begins. The
	// saved anchor owns positioning during that handoff; normal screen tracking
	// must not re-anchor the large canvas as though it were the visible pill.
	guard !isAnimatingHandoffDeparture, handoffDepartureAnchor == nil else { return }
    let mouseLocation = NSEvent.mouseLocation
    guard let screenWithMouse = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
    currentScreen = screenWithMouse
    if let indicatorSize {
      updateFrame(size: indicatorSize, animated: false)
    }
  }

  private func checkForScreenChange() {
	guard !isAnimatingHandoffDeparture, handoffDepartureAnchor == nil else { return }
    let mouseLocation = NSEvent.mouseLocation
    guard let newScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
    
    // Only update if screen actually changed
    if newScreen !== currentScreen {
      currentScreen = newScreen
      if let indicatorSize {
        updateFrame(size: indicatorSize, animated: false)
      }
    }
  }

  @objc private func screenDidChange(_: Notification) {
    updateToScreenWithMouse()
  }

  private func updateFrame(size: CGSize, animated: Bool) {
    guard let screen = currentScreen else { return }

    let horizontalInset: CGFloat = 24
    let verticalInset: CGFloat = 18
    let screenFrame = screen.frame
    let originX: CGFloat
    let originY: CGFloat

    switch indicatorLocation {
    case .topLeading, .bottomLeading:
      originX = screenFrame.minX + horizontalInset
    case .topCenter, .bottomCenter:
      originX = screenFrame.midX - size.width / 2
    case .topTrailing, .bottomTrailing:
      originX = screenFrame.maxX - horizontalInset - size.width
    }

    switch indicatorLocation {
    case .topLeading, .topCenter, .topTrailing:
      originY = screenFrame.maxY - verticalInset - size.height
    case .bottomLeading, .bottomCenter, .bottomTrailing:
      originY = screenFrame.minY + verticalInset
    }

    let newFrame = NSRect(origin: .init(x: originX, y: originY), size: size)
    guard animated else {
      setFrame(newFrame, display: true)
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.22
      animator().setFrame(newFrame, display: true)
    }
  }
}

extension InvisibleWindow: NSWindowDelegate {
  static func fromView<V: View>(_ view: V) -> InvisibleWindow {
    let window = InvisibleWindow()
    window.contentView = FirstMouseHostingView(rootView: AnyView(view))
    window.delegate = window
    return window
  }
}
