import XCTest

@testable import Claudophobia

final class ThresholdEvaluatorTests: XCTestCase {
   private func makeSnapshot(session: Double, weekly: Double) -> UsageSnapshot {
      UsageSnapshot(
         session: UsageLimit(utilization: session, resetAt: nil),
         weekly: UsageLimit(utilization: weekly, resetAt: nil),
         sonnet: nil,
         lastUpdated: Date(),
         orgName: nil
      )
   }

   func testCrossingThresholdFiresOnce() {
      let settings = AppSettings(sessionWarningThreshold: 80, weeklyWarningThreshold: 80)

      // 79% — under threshold, no event.
      var evaluation = ThresholdEvaluator.evaluate(
         accountID: "a1", snapshot: makeSnapshot(session: 79, weekly: 10),
         previous: nil, settings: settings, armed: [:]
      )
      XCTAssertTrue(evaluation.events.isEmpty)
      XCTAssertFalse(evaluation.armed["a1.session"] ?? false)

      // 81% — crossing fires.
      evaluation = ThresholdEvaluator.evaluate(
         accountID: "a1", snapshot: makeSnapshot(session: 81, weekly: 10),
         previous: nil, settings: settings, armed: evaluation.armed
      )
      XCTAssertEqual(evaluation.events, [.crossed(kind: .session, percentage: 81, resetAt: nil)])

      // 85% — still above, must NOT fire again.
      evaluation = ThresholdEvaluator.evaluate(
         accountID: "a1", snapshot: makeSnapshot(session: 85, weekly: 10),
         previous: nil, settings: settings, armed: evaluation.armed
      )
      XCTAssertTrue(evaluation.events.isEmpty)

      // Drop below threshold − hysteresis → re-arms.
      evaluation = ThresholdEvaluator.evaluate(
         accountID: "a1", snapshot: makeSnapshot(session: 70, weekly: 10),
         previous: nil, settings: settings, armed: evaluation.armed
      )
      XCTAssertTrue(evaluation.events.isEmpty)
      XCTAssertFalse(evaluation.armed["a1.session"] ?? true)

      // Crossing again fires.
      evaluation = ThresholdEvaluator.evaluate(
         accountID: "a1", snapshot: makeSnapshot(session: 90, weekly: 10),
         previous: nil, settings: settings, armed: evaluation.armed
      )
      XCTAssertEqual(evaluation.events, [.crossed(kind: .session, percentage: 90, resetAt: nil)])
   }

   func testWeeklyCrossingIsIndependent() {
      let settings = AppSettings(sessionWarningThreshold: 80, weeklyWarningThreshold: 80)
      let evaluation = ThresholdEvaluator.evaluate(
         accountID: "a1", snapshot: makeSnapshot(session: 10, weekly: 95),
         previous: nil, settings: settings, armed: [:]
      )
      XCTAssertEqual(evaluation.events, [.crossed(kind: .weekly, percentage: 95, resetAt: nil)])
   }

   func testRefreshDetection() {
      let settings = AppSettings(notifyOnReset: true)
      let previous = makeSnapshot(session: 72, weekly: 90)
      let evaluation = ThresholdEvaluator.evaluate(
         accountID: "a1", snapshot: makeSnapshot(session: 0, weekly: 3),
         previous: previous, settings: settings, armed: [:]
      )
      XCTAssertEqual(
         evaluation.events,
         [
            .refreshed(kind: .session),
            .refreshed(kind: .weekly),
         ])
   }

   func testNoRefreshWithoutPrevious() {
      let settings = AppSettings(notifyOnReset: true)
      let evaluation = ThresholdEvaluator.evaluate(
         accountID: "a1", snapshot: makeSnapshot(session: 2, weekly: 2),
         previous: nil, settings: settings, armed: [:]
      )
      XCTAssertTrue(evaluation.events.isEmpty)
   }

   func testRefreshRespectsNotifyOnResetFlag() {
      let settings = AppSettings(notifyOnReset: false)
      let previous = makeSnapshot(session: 70, weekly: 10)
      let evaluation = ThresholdEvaluator.evaluate(
         accountID: "a1", snapshot: makeSnapshot(session: 0, weekly: 5),
         previous: previous, settings: settings, armed: [:]
      )
      XCTAssertTrue(evaluation.events.isEmpty)
   }
}
