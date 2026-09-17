import XCTest
@testable import Claudophobia

final class CodexAPIDecodingTests: XCTestCase {
   func testUsageResponseMapsPrimaryAndSecondaryWindows() throws {
      let json = "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":25,\"reset_at\":1730000000},\"secondary_window\":{\"used_percent\":10,\"reset_at\":1730001200}}}"

      let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
      let snapshot = response.snapshot(accountName: "Codex")
      XCTAssertEqual(snapshot.session.utilization, 25)
      XCTAssertEqual(snapshot.weekly.utilization, 10)
      XCTAssertEqual(snapshot.orgName, "Codex")
   }

   func testAuthReadsCodexAuthShape() throws {
      let json = "{\"tokens\":{\"access_token\":\"token\",\"account_id\":\"account\"}}"
      let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
      try Data(json.utf8).write(to: url)
      defer { try? FileManager.default.removeItem(at: url) }
      let auth = try CodexAuth.load(fileURL: url)
      XCTAssertEqual(auth.accessToken, "token")
      XCTAssertEqual(auth.accountID, "account")
   }
}
