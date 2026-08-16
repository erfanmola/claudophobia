import Foundation
import Security

/// Stores Claude session keys in the macOS Keychain, keyed by account id.
enum KeychainStore {
   private static let service = "com.claudophobia.claude-session"

   enum KeychainError: LocalizedError {
      case notFound
      case osStatus(OSStatus)

      var errorDescription: String? {
         switch self {
         case .notFound: return "No session key found in Keychain."
         case .osStatus(let status): return "Keychain error (\(status))."
         }
      }
   }

   static func save(_ value: String, account: String) throws {
      let data = Data(value.utf8)
      let baseQuery: [String: Any] = [
         kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
      ]

      let updateStatus = SecItemUpdate(
         baseQuery as CFDictionary,
         [kSecValueData as String: data] as CFDictionary
      )
      if updateStatus == errSecSuccess { return }

      if updateStatus == errSecItemNotFound {
         var addQuery = baseQuery
         addQuery[kSecValueData as String] = data
         // Accessible after first unlock: avoids "enter your password to unlock
         // the keychain" prompts when the app starts before the login keychain
         // has been unlocked (e.g. launch-at-login), or when the keychain is
         // locked on a fresh boot.
         addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
         let status = SecItemAdd(addQuery as CFDictionary, nil)
         guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
         }
      } else {
         throw KeychainError.osStatus(updateStatus)
      }
   }

   static func load(account: String) throws -> String {
      let query: [String: Any] = [
         kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecReturnData as String: true,
         kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      guard status == errSecSuccess,
         let data = result as? Data,
         let value = String(data: data, encoding: .utf8)
      else {
         throw KeychainError.notFound
      }
      return value
   }

   static func delete(account: String) {
      let query: [String: Any] = [
         kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
      ]
      SecItemDelete(query as CFDictionary)
   }
}

// MARK: - Session key parsing

enum SessionKeyError: LocalizedError {
   case invalidFormat

   var errorDescription: String? {
      "Session key must be a `sk-ant-…` value."
   }
}

/// A validated Claude `sessionKey` cookie value.
struct SessionKey: Equatable, Sendable {
   let value: String

   init(_ rawValue: String) throws {
      guard let extracted = Self.extract(from: rawValue), extracted.hasPrefix("sk-ant-") else {
         throw SessionKeyError.invalidFormat
      }
      self.value = extracted
   }

   /// Accepts a raw `sk-ant-…` value or a Cookie header containing `sessionKey=sk-ant-…`.
   static func extract(from rawValue: String) -> String? {
      let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if trimmed.hasPrefix("sk-ant-") { return trimmed }

      let pattern = #"(?i)(?:^|[;\s])sessionKey\s*=\s*([^;\s'"]+)"#
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
      let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
      guard let match = regex.firstMatch(in: trimmed, range: range),
         match.numberOfRanges >= 2,
         let capture = Range(match.range(at: 1), in: trimmed)
      else {
         return nil
      }
      return String(trimmed[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
   }
}
