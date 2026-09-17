import Foundation

// MARK: - OpenAI Codex usage client

/// Reads the OAuth token maintained by Codex and queries its private usage API.
/// This endpoint is used by the Codex app/CLI and may change without notice.
actor CodexAPI {
   private let base = "https://chatgpt.com/backend-api"
   private let session: URLSession

   init() {
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 30
      config.timeoutIntervalForResource = 30
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      session = URLSession(configuration: config)
   }

   func usage() async throws -> CodexUsageResponse {
      let auth = try CodexAuth.load()
      guard let url = URL(string: base + "/codex/usage") else {
         throw ClaudeAPIError.network("bad Codex URL")
      }
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
      request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
      request.setValue("us", forHTTPHeaderField: "x-openai-internal-codex-residency")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue("Codex Desktop", forHTTPHeaderField: "User-Agent")

      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
         throw ClaudeAPIError.network("invalid Codex response")
      }
      switch http.statusCode {
      case 200..<300:
         do { return try JSONDecoder().decode(CodexUsageResponse.self, from: data) }
         catch { throw ClaudeAPIError.decoding("Codex usage (\(error.localizedDescription))") }
      case 401, 403: throw ClaudeAPIError.invalidSession
      case 429, 402: throw ClaudeAPIError.rateLimited
      default: throw ClaudeAPIError.network("Codex HTTP \(http.statusCode)")
      }
   }
}

struct CodexAuth: Decodable, Sendable {
   struct Tokens: Decodable, Sendable {
      let accessToken: String
      let accountID: String

      private enum CodingKeys: String, CodingKey {
         case accessToken = "access_token"
         case accountID = "account_id"
      }
   }

   let tokens: Tokens

   var accessToken: String { tokens.accessToken }
   var accountID: String { tokens.accountID }

   static func load(fileURL: URL? = nil) throws -> CodexAuth {
      let url = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
         .appendingPathComponent(".codex/auth.json")
      do {
         return try JSONDecoder().decode(CodexAuth.self, from: Data(contentsOf: url))
      } catch {
         throw ClaudeAPIError.network("Codex login not found — sign in with Codex first")
      }
   }
}

struct CodexUsageResponse: Decodable, Sendable {
   let planType: String?
   let rateLimit: CodexRateLimit

   private enum CodingKeys: String, CodingKey {
      case planType = "plan_type"
      case rateLimit = "rate_limit"
   }

   func snapshot(accountName: String?) -> UsageSnapshot {
      let now = Date()
      let primary = rateLimit.primaryWindow ?? .empty
      let secondary = rateLimit.secondaryWindow ?? primary
      return UsageSnapshot(
         session: primary.limit,
         weekly: secondary.limit,
         sonnet: nil,
         lastUpdated: now,
         orgName: accountName
      )
   }
}

struct CodexRateLimit: Decodable, Sendable {
   let primaryWindow: CodexWindow?
   let secondaryWindow: CodexWindow?

   private enum CodingKeys: String, CodingKey {
      case primaryWindow = "primary_window"
      case secondaryWindow = "secondary_window"
   }
}

struct CodexWindow: Decodable, Sendable {
   let usedPercent: Double
   let resetAt: TimeInterval?

   private enum CodingKeys: String, CodingKey {
      case usedPercent = "used_percent"
      case resetAt = "reset_at"
   }

   var limit: UsageLimit {
      UsageLimit(utilization: usedPercent, resetAt: resetAt.map(Date.init(timeIntervalSince1970:)))
   }

   static let empty = CodexWindow(usedPercent: 0, resetAt: nil)
}
