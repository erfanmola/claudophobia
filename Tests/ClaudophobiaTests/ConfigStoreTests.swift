import XCTest

@testable import Claudophobia

final class ConfigStoreTests: XCTestCase {
   private func makeStore() throws -> ConfigStore {
      let url = FileManager.default.temporaryDirectory
         .appendingPathComponent("claudophobia-tests-\(UUID().uuidString)")
         .appendingPathComponent("config.json")
      return ConfigStore(fileURL: url)
   }

   func testRoundTrip() throws {
      let store = try makeStore()
      var config = AppConfig()
      config.accounts = [
         ClaudeAccount(name: "Work", orgID: "uuid-1", orgName: "Work")
      ]
      config.activeAccountID = config.accounts[0].id
      config.settings.sessionWarningThreshold = 85
      config.history["x"] = [UsageSample(date: Date(), session: 12, weekly: 34)]

      store.save(config)
      let loaded = store.load()

      XCTAssertEqual(loaded.accounts, config.accounts)
      XCTAssertEqual(loaded.activeAccountID, config.activeAccountID)
      XCTAssertEqual(loaded.settings.sessionWarningThreshold, 85)
      XCTAssertEqual(loaded.history["x"]?.count, 1)
   }

   func testLoadMissingFileGivesDefaults() throws {
      let store = try makeStore()
      let config = store.load()
      XCTAssertTrue(config.accounts.isEmpty)
      XCTAssertNil(config.activeAccountID)
      XCTAssertEqual(config.settings.sessionWarningThreshold, 80)
      XCTAssertEqual(config.settings.pollInterval, 120)
   }

   func testBackwardCompatibleDecoding() throws {
      // A config written by an older build that lacks newer fields.
      let json = """
         {"accounts": [], "settings": {"pollInterval": 300, "launchAtLogin": true}}
         """
      let url = FileManager.default.temporaryDirectory
         .appendingPathComponent("claudophobia-old-\(UUID().uuidString)")
         .appendingPathComponent("config.json")
      try? FileManager.default.createDirectory(
         at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(json.utf8).write(to: url)

      let store = ConfigStore(fileURL: url)
      let config = store.load()
      XCTAssertEqual(config.settings.pollInterval, 300)
      XCTAssertTrue(config.settings.launchAtLogin)
      XCTAssertEqual(
         config.settings.sessionWarningThreshold, 80, "missing thresholds default to 80")
      XCTAssertEqual(config.settings.weeklyWarningThreshold, 80)
      XCTAssertNil(config.activeAccountID)
   }
}
