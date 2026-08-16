import Foundation

// MARK: - Claude.ai API client

enum ClaudeAPIError: LocalizedError, Equatable {
   case invalidSession
   case rateLimited
   case network(String)
   case decoding(String)
   case noOrganizations

   var errorDescription: String? {
      switch self {
      case .invalidSession: return "Session expired or invalid. Sign in again."
      case .rateLimited: return "Claude is rate-limiting requests. Retrying later."
      case .network(let message): return "Network error: \(message)"
      case .decoding(let message): return "Unexpected response: \(message)"
      case .noOrganizations: return "No Claude organization found for this account."
      }
   }
}

/// Thin client for the (undocumented) claude.ai consumer API.
/// Auth is the `sessionKey` cookie from claude.ai, sent as a Cookie header.
actor ClaudeAPI {
   private let base = "https://claude.ai/api"
   private let session: URLSession

   init() {
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 30
      config.timeoutIntervalForResource = 30
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      self.session = URLSession(configuration: config)
   }

   /// List of organizations the session key can access.
   func organizations(sessionKey: String) async throws -> [Organization] {
      let data = try await request("/organizations", sessionKey: sessionKey)
      do {
         return try JSONDecoder().decode([Organization].self, from: data)
      } catch {
         throw ClaudeAPIError.decoding("organizations (\(error.localizedDescription))")
      }
   }

   /// Usage for one organization: 5-hour session + 7-day weekly (+ Sonnet-specific).
   func usage(orgID: String, sessionKey: String) async throws -> UsageResponse {
      let data = try await request("/organizations/\(orgID)/usage", sessionKey: sessionKey)
      do {
         return try JSONDecoder().decode(UsageResponse.self, from: data)
      } catch {
         throw ClaudeAPIError.decoding("usage (\(error.localizedDescription))")
      }
   }

   private func request(_ path: String, sessionKey: String) async throws -> Data {
      guard let url = URL(string: base + path) else {
         throw ClaudeAPIError.network("bad URL")
      }
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue(
         "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
         forHTTPHeaderField: "User-Agent"
      )
      request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
      request.setValue("claude.ai", forHTTPHeaderField: "Origin")
      request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
      request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
      request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")

      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
         throw ClaudeAPIError.network("invalid response")
      }
      switch http.statusCode {
      case 200..<300:
         return data
      case 401, 403:
         throw ClaudeAPIError.invalidSession
      case 429:
         throw ClaudeAPIError.rateLimited
      default:
         throw ClaudeAPIError.network("HTTP \(http.statusCode)")
      }
   }
}

// MARK: - Wire models

/// An organization. The live API returns `organization_uuid`; older snapshots used `uuid`.
struct Organization: Codable, Equatable, Sendable {
   let id: Int
   let uuid: String
   let name: String

   private enum Keys: String, CodingKey {
      case id
      case uuid
      case organizationUUID = "organization_uuid"
      case name
   }

   init(id: Int, uuid: String, name: String) {
      self.id = id
      self.uuid = uuid
      self.name = name
   }

   init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
      name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
      if let u = try? c.decode(String.self, forKey: .uuid), !u.isEmpty {
         uuid = u
      } else if let u = try? c.decode(String.self, forKey: .organizationUUID), !u.isEmpty {
         uuid = u
      } else {
         uuid = ""
      }
   }

   func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: Keys.self)
      try c.encode(id, forKey: .id)
      try c.encode(uuid, forKey: .uuid)
      try c.encode(name, forKey: .name)
   }
}

/// Response of `GET /organizations/{org}/usage`.
struct UsageResponse: Decodable, Sendable {
   let fiveHour: LimitResponse
   let sevenDay: LimitResponse
   let sevenDaySonnet: LimitResponse?

   private enum Keys: String, CodingKey {
      case fiveHour = "five_hour"
      case sevenDay = "seven_day"
      case sevenDaySonnet = "seven_day_sonnet"
   }

   init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      fiveHour =
         try c.decodeIfPresent(LimitResponse.self, forKey: .fiveHour)
         ?? LimitResponse(utilization: 0, resetsAt: nil)
      sevenDay =
         try c.decodeIfPresent(LimitResponse.self, forKey: .sevenDay)
         ?? LimitResponse(utilization: 0, resetsAt: nil)
      sevenDaySonnet = try c.decodeIfPresent(LimitResponse.self, forKey: .sevenDaySonnet)
   }

   func snapshot(orgName: String?) -> UsageSnapshot {
      let now = Date()
      let sessionReset = Self.parseDate(fiveHour.resetsAt) ?? now.addingTimeInterval(5 * 3600)
      let weeklyReset = Self.parseDate(sevenDay.resetsAt) ?? now.addingTimeInterval(7 * 86400)
      return UsageSnapshot(
         session: UsageLimit(utilization: fiveHour.utilization, resetAt: sessionReset),
         weekly: UsageLimit(utilization: sevenDay.utilization, resetAt: weeklyReset),
         sonnet: sevenDaySonnet.map {
            UsageLimit(
               utilization: $0.utilization,
               resetAt: Self.parseDate($0.resetsAt) ?? now.addingTimeInterval(7 * 86400)
            )
         },
         lastUpdated: now,
         orgName: orgName
      )
   }

   private static func parseDate(_ raw: String?) -> Date? {
      guard let raw else { return nil }
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: raw) { return date }
      let plain = ISO8601DateFormatter()
      plain.formatOptions = [.withInternetDateTime]
      return plain.date(from: raw)
   }
}

struct LimitResponse: Decodable, Sendable {
   let utilization: Double
   let resetsAt: String?

   private enum Keys: String, CodingKey {
      case utilization
      case resetsAt = "resets_at"
   }

   init(utilization: Double, resetsAt: String?) {
      self.utilization = utilization
      self.resetsAt = resetsAt
   }

   init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      utilization = try c.decodeIfPresent(Double.self, forKey: .utilization) ?? 0
      resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
   }
}
