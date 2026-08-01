import AppKit
import XCTest

@testable import Octo

@MainActor
final class InvisibleWindowTests: XCTestCase {
  func testTopCenterIndicatorSitsFortyEightPointsBelowScreenEdge() {
    let screenFrame = NSRect(x: 0, y: 0, width: 1_512, height: 982)
    let size = CGSize(width: 272, height: 56)

    let frame = InvisibleWindow.indicatorFrame(
      size: size,
      location: .topCenter,
      screenFrame: screenFrame
    )

    XCTAssertEqual(frame.minX, 620)
    XCTAssertEqual(frame.minY, 878)
    XCTAssertEqual(screenFrame.maxY - frame.maxY, 48)
  }

  func testBottomCenterIndicatorKeepsEighteenPointInset() {
    let screenFrame = NSRect(x: 0, y: 0, width: 1_512, height: 982)
    let size = CGSize(width: 272, height: 56)

    let frame = InvisibleWindow.indicatorFrame(
      size: size,
      location: .bottomCenter,
      screenFrame: screenFrame
    )

    XCTAssertEqual(frame.minX, 620)
    XCTAssertEqual(frame.minY, 18)
  }
}
