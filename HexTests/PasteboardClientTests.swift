import ApplicationServices
import XCTest

@testable import Octo

final class PasteboardClientTests: XCTestCase {
	func testSelectedTextLookupPrefersApplicationFocus() {
		let applicationElement = AXUIElementCreateSystemWide()
		var didQuerySystemWideFocus = false

		let selection = PasteboardClientLive.firstFocusedSelection(
			applicationFocusedElement: { applicationElement },
			systemWideFocusedElement: {
				didQuerySystemWideFocus = true
				return nil
			},
			isValidSystemWideFocusedElement: { _ in false },
			selectionStartingAt: { element in
				.init(element: element, text: "Draft update")
			}
		)

		XCTAssertFalse(didQuerySystemWideFocus)
		XCTAssertEqual(selection?.text, "Draft update")
	}

	func testSelectedTextLookupFallsBackToSystemWideFocusWhenApplicationFocusIsUnavailable() {
		let fallbackElement = AXUIElementCreateSystemWide()
		var didQuerySystemWideFocus = false

		let selection = PasteboardClientLive.firstFocusedSelection(
			applicationFocusedElement: { nil },
			systemWideFocusedElement: {
				didQuerySystemWideFocus = true
				return fallbackElement
			},
			isValidSystemWideFocusedElement: { _ in true },
			selectionStartingAt: { element in
				.init(element: element, text: "Draft update")
			}
		)

		XCTAssertTrue(didQuerySystemWideFocus)
		XCTAssertEqual(selection?.text, "Draft update")
	}

	func testSelectedTextLookupRejectsSystemWideFocusFromAnotherProcess() {
		let fallbackElement = AXUIElementCreateSystemWide()
		var didAttemptSelection = false

		let selection = PasteboardClientLive.firstFocusedSelection(
			applicationFocusedElement: { nil },
			systemWideFocusedElement: { fallbackElement },
			isValidSystemWideFocusedElement: { _ in false },
			selectionStartingAt: { _ in
				didAttemptSelection = true
				return nil
			}
		)

		XCTAssertNil(selection)
		XCTAssertFalse(didAttemptSelection)
	}
}
