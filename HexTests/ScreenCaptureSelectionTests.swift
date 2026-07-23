import CoreGraphics
import XCTest

@testable import Octo

final class ScreenCaptureSelectionTests: XCTestCase {
	func testDragNormalizesSelectionRectangle() {
		var selection = ScreenCaptureSelection()
		selection.begin(at: CGPoint(x: 80, y: 90))
		selection.drag(to: CGPoint(x: 20, y: 30))

		XCTAssertEqual(selection.finish(at: CGPoint(x: 20, y: 30)), CGRect(x: 20, y: 30, width: 60, height: 60))
	}

	func testMovingPreservesSelectionSize() {
		var selection = ScreenCaptureSelection()
		selection.begin(at: CGPoint(x: 10, y: 10))
		selection.drag(to: CGPoint(x: 40, y: 30))
		selection.beginMoving(at: CGPoint(x: 40, y: 30))
		selection.drag(to: CGPoint(x: 70, y: 50))

		XCTAssertEqual(selection.rectangle, CGRect(x: 40, y: 30, width: 30, height: 20))
	}

	func testReleasingSpaceRetainsTheMovedRectangleAsTheResizeBaseline() {
		var selection = ScreenCaptureSelection()
		selection.begin(at: CGPoint(x: 10, y: 10))
		selection.drag(to: CGPoint(x: 40, y: 30))
		selection.beginMoving(at: CGPoint(x: 40, y: 30))
		selection.drag(to: CGPoint(x: 70, y: 50))
		selection.endMoving()

		XCTAssertEqual(selection.finish(at: CGPoint(x: 90, y: 60)), CGRect(x: 40, y: 30, width: 50, height: 30))
	}

	func testEscapeResetsInitialDragForRetry() {
		var selection = ScreenCaptureSelection()
		selection.begin(at: CGPoint(x: 10, y: 10))
		selection.drag(to: CGPoint(x: 40, y: 30))

		XCTAssertTrue(selection.reset())
		XCTAssertNil(selection.rectangle)

		selection.begin(at: CGPoint(x: 20, y: 20))
		XCTAssertEqual(selection.finish(at: CGPoint(x: 50, y: 60)), CGRect(x: 20, y: 20, width: 30, height: 40))
	}

	func testClickDoesNotCreateARegion() {
		var selection = ScreenCaptureSelection()
		selection.begin(at: CGPoint(x: 40, y: 60))

		XCTAssertNil(selection.finish(at: CGPoint(x: 40, y: 60)))
	}

	func testShortDragDoesNotCreateARegion() {
		var selection = ScreenCaptureSelection(minimumDragDistance: 20)
		selection.begin(at: CGPoint(x: 40, y: 60))
		selection.drag(to: CGPoint(x: 52, y: 60))

		XCTAssertNil(selection.finish(at: CGPoint(x: 52, y: 60)))
	}

	func testDragAtThresholdCreatesARegion() {
		var selection = ScreenCaptureSelection(minimumDragDistance: 20)
		selection.begin(at: CGPoint(x: 40, y: 60))

		XCTAssertEqual(selection.finish(at: CGPoint(x: 52, y: 76)), CGRect(x: 40, y: 60, width: 12, height: 16))
	}

	func testPixelRectFlipsAppKitYAxisAndClampsToImageBounds() {
		let pixelRect = ScreenCaptureSelection.pixelRect(
			for: CGRect(x: 40, y: 20, width: 80, height: 50),
			displayPointSize: CGSize(width: 200, height: 100),
			backingScaleFactor: 2,
			imageSize: CGSize(width: 400, height: 200)
		)

		XCTAssertEqual(pixelRect, CGRect(x: 80, y: 60, width: 160, height: 100))
	}
}
