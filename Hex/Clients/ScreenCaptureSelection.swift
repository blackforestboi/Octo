import CoreGraphics

struct ScreenCaptureSelection {
	private enum Phase {
		case idle
		case drawing(anchor: CGPoint, hasExceededDragThreshold: Bool)
		case moving(initialPointer: CGPoint, rectangle: CGRect, resizeAnchor: CGPoint, latestPointer: CGPoint)
	}

	private let minimumDragDistance: CGFloat
	private var phase: Phase = .idle
	private(set) var rectangle: CGRect?

	init(minimumDragDistance: CGFloat = 20) {
		self.minimumDragDistance = minimumDragDistance
	}

	var isActive: Bool {
		switch phase {
		case .idle: false
		case .drawing, .moving: true
		}
	}

	mutating func begin(at point: CGPoint) {
		rectangle = nil
		phase = .drawing(anchor: point, hasExceededDragThreshold: false)
	}

	mutating func drag(to point: CGPoint) {
		switch phase {
		case .idle:
			break
		case let .drawing(anchor, hasExceededDragThreshold):
			let didExceedDragThreshold = hasExceededDragThreshold || Self.distance(from: anchor, to: point) >= minimumDragDistance
			phase = .drawing(anchor: anchor, hasExceededDragThreshold: didExceedDragThreshold)
			guard didExceedDragThreshold else {
				rectangle = nil
				return
			}
			rectangle = Self.rectangle(from: anchor, to: point)
		case let .moving(initialPointer, originalRectangle, resizeAnchor, _):
			rectangle = originalRectangle.offsetBy(dx: point.x - initialPointer.x, dy: point.y - initialPointer.y)
			phase = .moving(
				initialPointer: initialPointer,
				rectangle: originalRectangle,
				resizeAnchor: resizeAnchor,
				latestPointer: point
			)
		}
	}

	mutating func beginMoving(at point: CGPoint) {
		guard let rectangle else { return }
		phase = .moving(
			initialPointer: point,
			rectangle: rectangle,
			resizeAnchor: Self.oppositeCorner(of: rectangle, from: point),
			latestPointer: point
		)
	}

	mutating func endMoving() {
		guard case let .moving(initialPointer, _, resizeAnchor, latestPointer) = phase else { return }
		phase = .drawing(
			anchor: CGPoint(
				x: resizeAnchor.x + latestPointer.x - initialPointer.x,
				y: resizeAnchor.y + latestPointer.y - initialPointer.y
			),
			hasExceededDragThreshold: true
		)
	}

	mutating func finish(at point: CGPoint) -> CGRect? {
		drag(to: point)
		phase = .idle
		guard let rectangle, !rectangle.isEmpty else { return nil }
		return rectangle
	}

	@discardableResult
	mutating func reset() -> Bool {
		guard isActive else { return false }
		rectangle = nil
		phase = .idle
		return true
	}

	static func pixelRect(
		for selection: CGRect,
		displayPointSize: CGSize,
		backingScaleFactor: CGFloat,
		imageSize: CGSize
	) -> CGRect? {
		guard displayPointSize.width > 0, displayPointSize.height > 0, backingScaleFactor > 0 else {
			return nil
		}

		let displayRect = CGRect(origin: .zero, size: displayPointSize)
		let clampedSelection = selection.intersection(displayRect)
		guard !clampedSelection.isNull, !clampedSelection.isEmpty else { return nil }

		let scaledRect = CGRect(
			x: clampedSelection.minX * backingScaleFactor,
			y: (displayPointSize.height - clampedSelection.maxY) * backingScaleFactor,
			width: clampedSelection.width * backingScaleFactor,
			height: clampedSelection.height * backingScaleFactor
		).integral
		let imageBounds = CGRect(origin: .zero, size: imageSize)
		let croppedRect = scaledRect.intersection(imageBounds)
		guard !croppedRect.isNull, !croppedRect.isEmpty else { return nil }
		return croppedRect
	}

	private static func rectangle(from anchor: CGPoint, to point: CGPoint) -> CGRect {
		CGRect(
			x: min(anchor.x, point.x),
			y: min(anchor.y, point.y),
			width: abs(point.x - anchor.x),
			height: abs(point.y - anchor.y)
		)
	}

	private static func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
		let horizontal = second.x - first.x
		let vertical = second.y - first.y
		return (horizontal * horizontal + vertical * vertical).squareRoot()
	}

	private static func oppositeCorner(of rectangle: CGRect, from point: CGPoint) -> CGPoint {
		let activeX = point.x >= rectangle.midX ? rectangle.maxX : rectangle.minX
		let activeY = point.y >= rectangle.midY ? rectangle.maxY : rectangle.minY
		return CGPoint(
			x: activeX == rectangle.minX ? rectangle.maxX : rectangle.minX,
			y: activeY == rectangle.minY ? rectangle.maxY : rectangle.minY
		)
	}
}
