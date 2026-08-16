import XCTest

@testable import Claudophobia

final class SessionKeyTests: XCTestCase {
   func testRawSessionKey() throws {
      let key = try SessionKey("sk-ant-abc123")
      XCTAssertEqual(key.value, "sk-ant-abc123")
   }

   func testWhitespaceTrimmed() throws {
      let key = try SessionKey("  sk-ant-abc123 \n")
      XCTAssertEqual(key.value, "sk-ant-abc123")
   }

   func testCookieHeaderExtraction() throws {
      let header = "sessionKey=sk-ant-xyz; other=1; another=two"
      let key = try SessionKey(header)
      XCTAssertEqual(key.value, "sk-ant-xyz")
   }

   func testExtractHandlesJunk() {
      XCTAssertNil(SessionKey.extract(from: "sk-ant"))
      XCTAssertNil(SessionKey.extract(from: "hello world"))
      XCTAssertNil(SessionKey.extract(from: ""))
      XCTAssertNil(SessionKey.extract(from: "  "))
   }

   func testRejectsNonAnthropicKey() {
      XCTAssertThrowsError(try SessionKey("sk-other-prefix"))
   }
}
