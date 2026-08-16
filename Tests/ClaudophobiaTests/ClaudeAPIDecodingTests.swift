import XCTest

@testable import Claudophobia

final class ClaudeAPIDecodingTests: XCTestCase {
   func testOrganizationWithOrganizationUUID() throws {
      let json = """
         [
           {"id": 1, "organization_uuid": "11111111-2222-3333-4444-555555555555", "name": "Acme"}
         ]
         """
      let orgs = try JSONDecoder().decode([Organization].self, from: Data(json.utf8))
      XCTAssertEqual(orgs.count, 1)
      XCTAssertEqual(orgs[0].id, 1)
      XCTAssertEqual(orgs[0].uuid, "11111111-2222-3333-4444-555555555555")
      XCTAssertEqual(orgs[0].name, "Acme")
   }

   func testOrganizationWithUuidKey() throws {
      let json = """
         [{"id": 7, "uuid": "aaaa-bbbb", "name": "Beta"}]
         """
      let orgs = try JSONDecoder().decode([Organization].self, from: Data(json.utf8))
      XCTAssertEqual(orgs[0].uuid, "aaaa-bbbb")
      XCTAssertEqual(orgs[0].name, "Beta")
   }

   func testUsageResponseFull() throws {
      let json = """
         {
           "five_hour": {"utilization": 62.5, "resets_at": "2026-08-16T06:00:00.000Z"},
           "seven_day": {"utilization": 88.0, "resets_at": "2026-08-18T00:00:00.000Z"},
           "seven_day_sonnet": {"utilization": 40.0, "resets_at": "2026-08-18T00:00:00.000Z"}
         }
         """
      let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
      XCTAssertEqual(response.fiveHour.utilization, 62.5)
      XCTAssertEqual(response.sevenDay.utilization, 88.0)
      XCTAssertNotNil(response.sevenDaySonnet)
      XCTAssertEqual(response.sevenDaySonnet?.utilization, 40.0)
   }

   func testUsageResponseMissingSonnetAndResets() throws {
      let json = """
         {
           "five_hour": {"utilization": 10.0},
           "seven_day": {"utilization": 20.0}
         }
         """
      let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
      XCTAssertNil(response.sevenDaySonnet)
      XCTAssertEqual(response.fiveHour.utilization, 10.0)
      // Missing resets_at falls back to default windows.
      let snapshot = response.snapshot(orgName: nil)
      XCTAssertNotNil(snapshot.session.resetAt)
      XCTAssertNotNil(snapshot.weekly.resetAt)
      let sessionDelta = snapshot.session.resetAt!.timeIntervalSinceNow
      XCTAssertEqual(sessionDelta, 5 * 3600, accuracy: 30)
      let weeklyDelta = snapshot.weekly.resetAt!.timeIntervalSinceNow
      XCTAssertEqual(weeklyDelta, 7 * 86400, accuracy: 30)
   }

   func testUsageSnapshotParsesPlainAndFractionalDates() throws {
      let fractional = """
         {"five_hour": {"utilization": 1, "resets_at": "2026-08-16T06:00:00.123Z"},
          "seven_day": {"utilization": 2, "resets_at": "2026-08-18T00:00:00Z"}}
         """
      let response = try JSONDecoder().decode(UsageResponse.self, from: Data(fractional.utf8))
      let snapshot = response.snapshot(orgName: nil)
      XCTAssertNotNil(snapshot.session.resetAt)
      XCTAssertNotNil(snapshot.weekly.resetAt)
   }
}
