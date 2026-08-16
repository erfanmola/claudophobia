import XCTest

@testable import Claudophobia

final class UsageLimitTests: XCTestCase {
   func testFractionClamped() {
      XCTAssertEqual(UsageLimit(utilization: 50, resetAt: nil).fraction, 0.5, accuracy: 0.001)
      XCTAssertEqual(UsageLimit(utilization: 0, resetAt: nil).fraction, 0, accuracy: 0.001)
      XCTAssertEqual(UsageLimit(utilization: 120, resetAt: nil).fraction, 1.0, accuracy: 0.001)
      XCTAssertEqual(UsageLimit(utilization: -5, resetAt: nil).fraction, 0, accuracy: 0.001)
   }

   func testStatusLevel() {
      XCTAssertEqual(UsageLimit(utilization: 10, resetAt: nil).statusLevel, .safe)
      XCTAssertEqual(UsageLimit(utilization: 49.9, resetAt: nil).statusLevel, .safe)
      XCTAssertEqual(UsageLimit(utilization: 50, resetAt: nil).statusLevel, .warning)
      XCTAssertEqual(UsageLimit(utilization: 79.9, resetAt: nil).statusLevel, .warning)
      XCTAssertEqual(UsageLimit(utilization: 80, resetAt: nil).statusLevel, .critical)
      XCTAssertEqual(UsageLimit(utilization: 100, resetAt: nil).statusLevel, .critical)
   }

   func testResetDescription() {
      let now = Date()
      let inMinutes = UsageLimit(utilization: 10, resetAt: now.addingTimeInterval(90))
         .resetDescription
      XCTAssertTrue(inMinutes.contains("2m"), inMinutes)

      let inHours = UsageLimit(utilization: 10, resetAt: now.addingTimeInterval(3.5 * 3600))
         .resetDescription
      XCTAssertTrue(inHours.contains("4h"), inHours)

      let inDays = UsageLimit(utilization: 10, resetAt: now.addingTimeInterval(50 * 3600))
         .resetDescription
      XCTAssertTrue(inDays.contains("2d"), inDays)

      let passed = UsageLimit(utilization: 10, resetAt: now.addingTimeInterval(-10))
         .resetDescription
      XCTAssertEqual(passed, "resetting…")

      XCTAssertEqual(UsageLimit(utilization: 10, resetAt: nil).resetDescription, "—")
   }

   func testIsExceeded() {
      XCTAssertTrue(UsageLimit(utilization: 100, resetAt: nil).isExceeded)
      XCTAssertTrue(UsageLimit(utilization: 142, resetAt: nil).isExceeded)
      XCTAssertFalse(UsageLimit(utilization: 99, resetAt: nil).isExceeded)
   }
}
