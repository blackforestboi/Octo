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

/// The transcription indicator's single overlay window. Its frame always
/// matches the visible pill/card so it can accept input without covering any
/// other part of the screen.
class InvisibleWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  private var currentScreen: NSScreen?
  private var mouseMonitor: Any?
  private var indicatorSize: CGSize?
  private var indicatorLocation: IndicatorLocation = .topCenter

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
    NotificationCenter.default.removeObserver(self)
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  func update(size: CGSize?, location: IndicatorLocation) {
    let previousSize = indicatorSize
    indicatorSize = size
    indicatorLocation = location

    guard let size, size.width > 0, size.height > 0 else {
      ignoresMouseEvents = true
      setFrame(.init(x: -2, y: -2, width: 1, height: 1), display: false)
      return
    }

    ignoresMouseEvents = false
    updateFrame(size: size, animated: previousSize != nil)
  }

  private func updateToScreenWithMouse() {
    let mouseLocation = NSEvent.mouseLocation
    guard let screenWithMouse = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }
    currentScreen = screenWithMouse
    if let indicatorSize {
      updateFrame(size: indicatorSize, animated: false)
    }
  }

  private func checkForScreenChange() {
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
