import AppKit

private final class ScreenCaptureSelectionWindow: NSPanel {
	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { true }
}

@MainActor
private final class ScreenCaptureSelectionOverlayController: NSObject, NSWindowDelegate {
	private let window: ScreenCaptureSelectionWindow
	private let backingScaleFactor: CGFloat
	private var continuation: CheckedContinuation<CGRect?, Error>?
	private var keyEventMonitor: Any?

	init(screenFrame: CGRect, backingScaleFactor: CGFloat) {
		self.backingScaleFactor = backingScaleFactor
		window = ScreenCaptureSelectionWindow(
			contentRect: screenFrame,
			styleMask: [.borderless, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		super.init()
		window.delegate = self
		window.level = .screenSaver
		window.backgroundColor = .clear
		window.isOpaque = false
		window.hasShadow = false
		window.hidesOnDeactivate = false
		window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
	}

	func select() async throws -> CGRect? {
		try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
			let view = ScreenCaptureSelectionOverlayView(
				frame: CGRect(origin: .zero, size: window.frame.size),
				minimumDragDistance: 20 / backingScaleFactor,
				onComplete: { [weak self] rectangle in self?.complete(with: rectangle) },
				onCancel: { [weak self] in self?.cancel() }
			)
			window.contentView = view
			keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak view] event in
				if event.type == .keyDown, view?.handleKeyDown(event) == true {
					return nil
				}
				if event.type == .keyUp, view?.handleKeyUp(event) == true {
					return nil
				}
				return event
			}
			NSApp.activate(ignoringOtherApps: true)
			window.makeKeyAndOrderFront(nil)
			window.makeFirstResponder(view)
		}
	}

	func windowWillClose(_: Notification) {
		cancel()
	}

	private func complete(with rectangle: CGRect?) {
		finish(.success(rectangle))
	}

	private func cancel() {
		finish(.failure(CancellationError()))
	}

	private func finish(_ result: Result<CGRect?, Error>) {
		guard let continuation else { return }
		self.continuation = nil
		if let keyEventMonitor {
			NSEvent.removeMonitor(keyEventMonitor)
			self.keyEventMonitor = nil
		}
		window.contentView = nil
		window.orderOut(nil)
		continuation.resume(with: result)
	}
}

@MainActor
enum ScreenCaptureSelectionOverlay {
	static func selectRegion(on screenFrame: CGRect, backingScaleFactor: CGFloat) async throws -> CGRect? {
		let controller = ScreenCaptureSelectionOverlayController(
			screenFrame: screenFrame,
			backingScaleFactor: backingScaleFactor
		)
		return try await controller.select()
	}
}

@MainActor
private final class ScreenCaptureSelectionOverlayView: NSView {
	private var selection = ScreenCaptureSelection()
	private let onComplete: (CGRect?) -> Void
	private let onCancel: () -> Void

	init(
		frame: CGRect,
		minimumDragDistance: CGFloat,
		onComplete: @escaping (CGRect?) -> Void,
		onCancel: @escaping () -> Void
	) {
		selection = ScreenCaptureSelection(minimumDragDistance: minimumDragDistance)
		self.onComplete = onComplete
		self.onCancel = onCancel
		super.init(frame: frame)
		wantsLayer = true
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var acceptsFirstResponder: Bool { true }

	override func resetCursorRects() {
		addCursorRect(bounds, cursor: .crosshair)
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.black.withAlphaComponent(0.28).setFill()
		bounds.fill()

		if let rectangle = selection.rectangle {
			let context = NSGraphicsContext.current?.cgContext
			context?.saveGState()
			context?.setBlendMode(.clear)
			context?.fill(rectangle)
			context?.restoreGState()

			NSColor.white.withAlphaComponent(0.9).setStroke()
			NSBezierPath(rect: rectangle).stroke()
		}

		let instructions = "Drag to select  •  Hold Space to move  •  Esc to retry"
		let attributes: [NSAttributedString.Key: Any] = [
			.font: NSFont.systemFont(ofSize: 13, weight: .medium),
			.foregroundColor: NSColor.white
		]
		let size = instructions.size(withAttributes: attributes)
		instructions.draw(
			at: CGPoint(x: (bounds.width - size.width) / 2, y: 24),
			withAttributes: attributes
		)
	}

	override func mouseDown(with event: NSEvent) {
		selection.begin(at: convert(event.locationInWindow, from: nil))
		needsDisplay = true
	}

	override func mouseDragged(with event: NSEvent) {
		selection.drag(to: convert(event.locationInWindow, from: nil))
		needsDisplay = true
	}

	override func mouseUp(with event: NSEvent) {
		onComplete(selection.finish(at: convert(event.locationInWindow, from: nil)))
	}

	override func keyDown(with event: NSEvent) {
		if handleKeyDown(event) {
			return
		}
		super.keyDown(with: event)
	}

	override func keyUp(with event: NSEvent) {
		if handleKeyUp(event) {
			return
		}
		super.keyUp(with: event)
	}

	@discardableResult
	func handleKeyDown(_ event: NSEvent) -> Bool {
		if isSpace(event) {
			guard !event.isARepeat else { return true }
			selection.beginMoving(at: convertMouseLocation())
			needsDisplay = true
			return true
		}
		if event.keyCode == 53 {
			if selection.reset() {
				needsDisplay = true
			} else {
				onCancel()
			}
			return true
		}
		return false
	}

	@discardableResult
	func handleKeyUp(_ event: NSEvent) -> Bool {
		guard isSpace(event) else { return false }
		selection.endMoving()
		needsDisplay = true
		return true
	}

	private func convertMouseLocation() -> CGPoint {
		convert(window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero, from: nil)
	}

	private func isSpace(_ event: NSEvent) -> Bool {
		event.keyCode == 49 || event.charactersIgnoringModifiers == " "
	}
}
