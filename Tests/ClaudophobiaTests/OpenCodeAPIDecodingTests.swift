import XCTest
@testable import Claudophobia

final class OpenCodeAPIDecodingTests: XCTestCase {
   func testGoUsageResponseMapsRollingAndWeeklyWindows() throws {
      let json = """
         {"usage":{
            "rolling":{"status":"ok","percent":25,"resetsAt":"2026-10-06T12:00:00Z"},
            "weekly":{"status":"ok","percent":10,"resetsAt":"2026-10-13T12:00:00Z"},
            "monthly":{"status":"ok","percent":5,"resetsAt":"2026-11-01T12:00:00Z"}
         }}
         """

      let response = try JSONDecoder().decode(
         OpenCodeGoUsageResponse.self, from: Data(json.utf8))
      let snapshot = response.snapshot(accountName: "OpenCode")
      XCTAssertEqual(snapshot.session.utilization, 25)
      XCTAssertEqual(snapshot.weekly.utilization, 10)
      XCTAssertEqual(snapshot.orgName, "OpenCode")
      XCTAssertNotNil(snapshot.session.resetAt)
   }

   func testGoUsageRateLimitedWindowMapsTo100() throws {
      let json = """
         {"usage":{
            "rolling":{"status":"rate-limited","percent":99,"resetsAt":"2026-10-06T12:00:00Z"},
            "weekly":{"status":"ok","percent":10,"resetsAt":"2026-10-13T12:00:00Z"}
         }}
         """

      let response = try JSONDecoder().decode(
         OpenCodeGoUsageResponse.self, from: Data(json.utf8))
      XCTAssertEqual(response.snapshot(accountName: nil).session.utilization, 100)
   }

   func testConsoleStatusMapsMeters() throws {
      let json = """
         {"access":{
            "endsAt":"2026-11-01T00:00:00Z",
            "meters":{
               "fiveHour":{"limitMicroCents":"1200000000","usedMicroCents":"300000000","resetsAt":"2026-10-06T12:00:00Z"},
               "week":{"limitMicroCents":3000000000,"usedMicroCents":900000000,"resetsAt":"2026-10-13T12:00:00Z"},
               "month":{"limitMicroCents":"6000000000","usedMicroCents":"900000000","resetsAt":"2026-11-01T00:00:00Z"}
            }
         }}
         """

      let response = try JSONDecoder().decode(
         OpenCodeConsoleStatusResponse.self, from: Data(json.utf8))
      let snapshot = try response.snapshot(accountName: "me@example.com")
      XCTAssertEqual(snapshot.session.utilization, 25)
      XCTAssertEqual(snapshot.weekly.utilization, 30)
   }

   func testConsoleStatusNullFiveHourResetHasNoResetDate() throws {
      // Live shape: fiveHour.resetsAt is null before anything is consumed.
      // It must render as "—", never as the subscription endsAt (~30d out).
      let json = """
         {"access":{
            "endsAt":"2026-11-06T12:45:52.000Z",
            "meters":{
               "fiveHour":{"startsAt":null,"resetsAt":null,"limitMicroCents":"1200000000","usedMicroCents":"0"},
               "week":{"startsAt":"2026-10-05T00:00:00.000Z","resetsAt":"2026-10-12T00:00:00Z","limitMicroCents":"3000000000","usedMicroCents":"0"}
            }
         }}
         """

      let response = try JSONDecoder().decode(
         OpenCodeConsoleStatusResponse.self, from: Data(json.utf8))
      let snapshot = try response.snapshot(accountName: nil)
      XCTAssertEqual(snapshot.session.utilization, 0)
      XCTAssertNil(snapshot.session.resetAt)
      XCTAssertEqual(snapshot.session.resetDescription, "—")
      XCTAssertNotNil(snapshot.weekly.resetAt)
   }

   func testGoUsageNullResetHasNoResetDate() throws {
      let json = """
         {"usage":{
            "rolling":{"status":"ok","percent":0,"resetsAt":null},
            "weekly":{"status":"ok","percent":10,"resetsAt":"2026-10-13T12:00:00Z"}
         }}
         """

      let response = try JSONDecoder().decode(
         OpenCodeGoUsageResponse.self, from: Data(json.utf8))
      let snapshot = response.snapshot(accountName: nil)
      XCTAssertNil(snapshot.session.resetAt)
      XCTAssertEqual(snapshot.session.resetDescription, "—")
   }
   func testConsoleStatusWithoutAccessIsNotSubscribed() throws {
      let response = try JSONDecoder().decode(
         OpenCodeConsoleStatusResponse.self, from: Data("{}".utf8))
      XCTAssertThrowsError(try response.snapshot(accountName: nil)) { error in
         XCTAssertTrue(error is OpenCodeGoStatusError)
      }
   }

   func testCredentialRowParsesAPIKeyAndOAuth() {
      let key = OpenCodeCredentialRow(json: ["type": "api", "key": "sk-123"])
      XCTAssertEqual(key.apiKey, "sk-123")
      XCTAssertNil(key.consoleCredential)

      let oauth = OpenCodeCredentialRow(json: [
         "type": "oauth",
         "access": "token",
         "metadata": ["server": "https://opencode.ai/console", "orgID": "org-1"],
      ])
      XCTAssertNil(oauth.apiKey)
      XCTAssertEqual(oauth.consoleCredential?.accessToken, "token")
      XCTAssertEqual(oauth.consoleCredential?.orgID, "org-1")
   }

   func testAuthLoadsAPIKeyFromEnvironment() throws {
      let auth = try OpenCodeAuth.load(
         environment: ["OPENCODE_API_KEY": "env-key"],
         configDir: URL(fileURLWithPath: NSTemporaryDirectory()),
         databaseURL: URL(fileURLWithPath: "/nonexistent/opencode.db")
      )
      XCTAssertEqual(auth.apiKey, "env-key")
      XCTAssertNil(auth.console)
   }

   func testAuthThrowsWithoutAnythingConfigured() {
      XCTAssertThrowsError(
         try OpenCodeAuth.load(
            environment: [:],
            configDir: URL(fileURLWithPath: NSTemporaryDirectory()),
            databaseURL: URL(fileURLWithPath: "/nonexistent/opencode.db")
         ))
   }
}
