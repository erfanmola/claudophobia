import Foundation

// MARK: - OpenCode (opencode.ai) usage client

/// Reads the credentials maintained by the OpenCode CLI (`opencode auth login`)
/// and queries the OpenCode Go quota endpoints. Supports two auth shapes:
///
/// - Console OAuth sign-in (`opencode` integration): `GET {server}/api/go/status`
/// - API-key login (`opencode-go` integration, `OPENCODE_API_KEY`, or global
///   `opencode.json[c]`): `GET https://opencode.ai/zen/go/v1/usage`
///
/// Both report rolling 5-hour, weekly, and monthly windows. The 5-hour and
/// weekly windows map onto the session/weekly gauges; monthly is ignored.
///
/// These are the same endpoints the `opencode-quota` plugin uses. They are
/// unofficial and may change without notice.
actor OpenCodeAPI {
   private let goUsageURL = "https://opencode.ai/zen/go/v1/usage"
   private let session: URLSession

   init() {
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 30
      config.timeoutIntervalForResource = 30
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      session = URLSession(configuration: config)
   }

   /// Usage snapshot for the locally signed-in OpenCode account.
   func usage() async throws -> UsageSnapshot {
      let auth = try OpenCodeAuth.load()
      if let console = auth.console {
         do {
            let status = try await goConsoleStatus(credential: console)
            return try status.snapshot(accountName: console.email ?? "OpenCode")
         } catch OpenCodeGoStatusError.notSubscribed {
            // Console sign-in without a Go subscription: fall back to an API
            // key if one is configured, otherwise surface the state.
            if auth.apiKey == nil {
               throw ClaudeAPIError.network(
                  "OpenCode Go subscription not found for this account")
            }
         }
      }
      guard let apiKey = auth.apiKey else {
         throw ClaudeAPIError.network("OpenCode login not found — sign in with OpenCode first")
      }
      return try await goQuota(apiKey: apiKey).snapshot(accountName: "OpenCode")
   }

   // MARK: - Requests

   private func goQuota(apiKey: String) async throws -> OpenCodeGoUsageResponse {
      guard let url = URL(string: goUsageURL) else {
         throw ClaudeAPIError.network("bad OpenCode URL")
      }
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")

      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
         throw ClaudeAPIError.network("invalid OpenCode response")
      }
      switch http.statusCode {
      case 200..<300:
         do { return try JSONDecoder().decode(OpenCodeGoUsageResponse.self, from: data) }
         catch { throw ClaudeAPIError.decoding("OpenCode usage (\(error.localizedDescription))") }
      case 401: throw ClaudeAPIError.invalidSession
      case 403 where isEntitlementError(data):
         throw OpenCodeGoStatusError.notSubscribed
      case 403: throw ClaudeAPIError.invalidSession
      case 429, 402: throw ClaudeAPIError.rateLimited
      default: throw ClaudeAPIError.network("OpenCode HTTP \(http.statusCode)")
      }
   }

   private func goConsoleStatus(credential: OpenCodeConsoleCredential) async throws
      -> OpenCodeConsoleStatusResponse
   {
      guard let url = URL(string: credential.server + "/api/go/status") else {
         throw ClaudeAPIError.network("bad OpenCode console URL")
      }
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      if let orgID = credential.orgID {
         request.setValue(orgID, forHTTPHeaderField: "x-org-id")
      }

      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
         throw ClaudeAPIError.network("invalid OpenCode response")
      }
      switch http.statusCode {
      case 200..<300:
         do { return try JSONDecoder().decode(OpenCodeConsoleStatusResponse.self, from: data) }
         catch { throw ClaudeAPIError.decoding("OpenCode usage (\(error.localizedDescription))") }
      case 404: throw OpenCodeGoStatusError.notSubscribed
      case 401, 403: throw ClaudeAPIError.invalidSession
      case 429: throw ClaudeAPIError.rateLimited
      default: throw ClaudeAPIError.network("OpenCode HTTP \(http.statusCode)")
      }
   }

   /// A 403 with an EntitlementError body means "no Go subscription", not a
   /// bad credential — don't prompt a re-login for it.
   private func isEntitlementError(_ data: Data) -> Bool {
      guard
         let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         json["type"] as? String == "error",
         let error = json["error"] as? [String: Any]
      else { return false }
      return error["type"] as? String == "EntitlementError"
   }
}

enum OpenCodeGoStatusError: Error {
   case notSubscribed
}

// MARK: - Auth

struct OpenCodeConsoleCredential: Sendable {
   let accessToken: String
   /// Console server, e.g. "https://opencode.ai/console".
   let server: String
   let orgID: String?
   let email: String?
}

/// Whatever OpenCode CLI auth was found locally: an API key, a Console
/// OAuth sign-in, or both.
struct OpenCodeAuth: Sendable {
   let apiKey: String?
   let console: OpenCodeConsoleCredential?

   var hasAuth: Bool { apiKey != nil || console != nil }

   /// Stable identifier for account matching (org, email, or shared key slot).
   var accountKey: String { console?.orgID ?? console?.email ?? "opencode-go" }

   static func load(
      environment: [String: String]? = nil,
      configDir: URL? = nil,
      databaseURL: URL? = nil
   ) throws -> OpenCodeAuth {
      let env = environment ?? ProcessInfo.processInfo.environment
      let home = FileManager.default.homeDirectoryForCurrentUser

      // 1. Explicit API key in the environment.
      var apiKey = env["OPENCODE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
      if apiKey?.isEmpty == true { apiKey = nil }

      // 2. Global opencode.jsonc / opencode.json (jsonc wins, like OpenCode).
      let dir =
         configDir
         ?? env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("opencode") }
         ?? home.appendingPathComponent(".config/opencode")
      if apiKey == nil {
         apiKey =
            readConfigAPIKey(at: dir.appendingPathComponent("opencode.jsonc"), environment: env)
            ?? readConfigAPIKey(at: dir.appendingPathComponent("opencode.json"), environment: env)
      }

      // 3. Credential rows in opencode.db (`opencode-go` API key or `opencode`
      // Console OAuth), via the sqlite3 CLI so we need no extra dependency.
      var console: OpenCodeConsoleCredential?
      let db =
         databaseURL
         ?? env["OPENCODE_DB"].map { URL(fileURLWithPath: $0) }
         ?? defaultDatabaseURL(home: home, environment: env)
      if let db, FileManager.default.fileExists(atPath: db.path) {
         let rows = readCredentialValues(databaseURL: db)
         for row in rows {
            if apiKey == nil, let key = row.apiKey { apiKey = key }
            if console == nil, let cred = row.consoleCredential { console = cred }
            if apiKey != nil, console != nil { break }
         }
      }

      guard apiKey != nil || console != nil else {
         throw ClaudeAPIError.network("OpenCode login not found — run `opencode auth login` first")
      }
      return OpenCodeAuth(apiKey: apiKey, console: console)
   }

   private static func defaultDatabaseURL(home: URL, environment: [String: String]) -> URL? {
      if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
         return URL(fileURLWithPath: xdg).appendingPathComponent("opencode/opencode.db")
      }
      return home.appendingPathComponent(".local/share/opencode/opencode.db")
   }

   /// Best-effort `apiKey` lookup for the `opencode-go` / `opencode` providers.
   /// Handles both the native `providers.<id>.settings.apiKey` shape and the
   /// legacy `provider.<id>.options.apiKey` shape, plus `${OPENCODE_API_KEY}`
   /// env templates (the only indirection OpenCode allows here).
   static func readConfigAPIKey(at url: URL, environment: [String: String]) -> String? {
      guard let data = try? Data(contentsOf: url) else { return nil }
      let json: Any
      if url.pathExtension == "jsonc" {
         json = (try? JSONSerialization.jsonObject(with: Data(stripJSONComments(data).utf8)))
            as Any? ?? NSNull()
      } else {
         json = (try? JSONSerialization.jsonObject(with: data)) as Any? ?? NSNull()
      }
      guard let root = json as? [String: Any] else { return nil }
      let paths: [[String]] = [
         ["providers", "opencode-go", "settings", "apiKey"],
         ["providers", "opencode", "settings", "apiKey"],
         ["provider", "opencode-go", "options", "apiKey"],
         ["provider", "opencode", "options", "apiKey"],
      ]
      for path in paths {
         var current: Any? = root
         for key in path { current = (current as? [String: Any])?[key] }
         guard let raw = (current as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
         else { continue }
         if let resolved = resolveEnvTemplate(raw, environment: environment) {
            return resolved
         }
      }
      return nil
   }

   /// Resolves `${VAR}` / `$VAR` using only OPENCODE_API_KEY (mirrors OpenCode).
   private static func resolveEnvTemplate(_ raw: String, environment: [String: String]) -> String? {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if trimmed.hasPrefix("${") && trimmed.hasSuffix("}") {
         let name = String(trimmed.dropFirst(2).dropLast())
         guard name == "OPENCODE_API_KEY" else { return nil }
         let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
         return value?.isEmpty == false ? value : nil
      }
      if trimmed.hasPrefix("$") {
         let name = String(trimmed.dropFirst())
         guard name == "OPENCODE_API_KEY" else { return nil }
         let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
         return value?.isEmpty == false ? value : nil
      }
      return trimmed
   }

   /// Strips `//` and `/* */` comments outside strings so jsonc parses.
   static func stripJSONComments(_ data: Data) -> String {
      guard let text = String(data: data, encoding: .utf8) else { return "" }
      var out = ""
      out.reserveCapacity(text.count)
      var iterator = text.makeIterator()
      var inString = false
      var escaped = false
      var current: Character? = iterator.next()
      func advance() -> Character? {
         let prev = current
         current = iterator.next()
         return prev
      }
      while let char = current {
         if inString {
            out.append(char)
            if escaped { escaped = false }
            else if char == "\\" { escaped = true }
            else if char == "\"" { inString = false }
            _ = advance()
            continue
         }
         if char == "\"" {
            inString = true
            out.append(char)
            _ = advance()
            continue
         }
         if char == "/" {
            _ = advance()
            if current == "/" {
               while let c = current, c != "\n" { _ = advance() }
               continue
            } else if current == "*" {
               _ = advance()
               var closed = false
               while let c = current {
                  if c == "*" {
                     _ = advance()
                     if current == "/" {
                        _ = advance()
                        closed = true
                        break
                     }
                     continue
                  }
                  _ = advance()
               }
               if !closed { break }
               continue
            } else {
               out.append("/")
               continue
            }
         }
         out.append(char)
         _ = advance()
      }
      return out
   }

   /// Dumps credential `value` JSON blobs with the system sqlite3 CLI
   /// (read-only; no new dependency).
   static func readCredentialValues(databaseURL: URL) -> [OpenCodeCredentialRow] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
      process.arguments = [
         "-readonly", "-separator", "\u{1F}",
         databaseURL.path,
         "SELECT value FROM credential WHERE integration_id IN ('opencode-go','opencode');",
      ]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch { return [] }
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return [] }
      let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
         ?? ""
      return output
         .split(separator: "\u{1F}")
         .flatMap { $0.split(separator: "\n") }
         .compactMap { line -> OpenCodeCredentialRow? in
            guard
               let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return OpenCodeCredentialRow(json: json)
         }
   }
}

/// One parsed `credential.value` blob from opencode.db.
struct OpenCodeCredentialRow: Sendable {
   let json: [String: Any]

   /// API-key rows store `{type: "api", key: "…"}` (older rows use "key" type).
   var apiKey: String? {
      guard let type = json["type"] as? String, type == "api" || type == "key" else { return nil }
      let key = (json["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return key?.isEmpty == false ? key : nil
   }

   /// Console OAuth rows store `{type: "oauth", access: "…", metadata: {...}}`.
   var consoleCredential: OpenCodeConsoleCredential? {
      guard (json["type"] as? String) == "oauth" else { return nil }
      guard
         let access = (json["access"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines),
         !access.isEmpty
      else { return nil }
      let metadata = json["metadata"] as? [String: Any] ?? [:]
      func string(_ keys: String...) -> String? {
         for key in keys {
            if let value = metadata[key] as? String, !value.isEmpty { return value }
         }
         return nil
      }
      return OpenCodeConsoleCredential(
         accessToken: access,
         server: string("server") ?? "https://opencode.ai/console",
         orgID: string("orgID", "org_id", "orgId"),
         email: string("email")
      )
   }
}

// MARK: - Wire models

/// Response of `GET https://opencode.ai/zen/go/v1/usage`.
struct OpenCodeGoUsageResponse: Decodable, Sendable {
   struct Window: Decodable, Sendable {
      let status: String
      let percent: Double
      /// Null when there is no active window (e.g. nothing consumed yet).
      let resetsAt: String?

      private enum CodingKeys: String, CodingKey {
         case status
         case percent
         case resetsAt
      }

      var isExhausted: Bool { status == "rate-limited" }

      var limit: UsageLimit {
         UsageLimit(
            utilization: isExhausted ? 100 : percent,
            resetAt: resetsAt.flatMap(Self.parseDate)
         )
      }

      static func parseDate(_ raw: String) -> Date? {
         let fractional = ISO8601DateFormatter()
         fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
         if let date = fractional.date(from: raw) { return date }
         let plain = ISO8601DateFormatter()
         plain.formatOptions = [.withInternetDateTime]
         return plain.date(from: raw)
      }
   }

   struct Usage: Decodable, Sendable {
      let rolling: Window
      let weekly: Window
      let monthly: Window?
   }

   let usage: Usage

   func snapshot(accountName: String?) -> UsageSnapshot {
      UsageSnapshot(
         session: usage.rolling.limit,
         weekly: usage.weekly.limit,
         sonnet: nil,
         lastUpdated: Date(),
         orgName: accountName
      )
   }
}

/// Response of `GET {console}/api/go/status`.
struct OpenCodeConsoleStatusResponse: Decodable, Sendable {
   struct Meter: Decodable, Sendable {
      let limitMicroCents: Double
      let usedMicroCents: Double
      let resetsAt: String?

      private enum CodingKeys: String, CodingKey {
         case limitMicroCents
         case usedMicroCents
         case resetsAt
      }

      init(from decoder: Decoder) throws {
         let c = try decoder.container(keyedBy: CodingKeys.self)
         limitMicroCents = try Self.microCents(c.decodeIfPresentAsDoubleOrString(.limitMicroCents))
         usedMicroCents = try Self.microCents(c.decodeIfPresentAsDoubleOrString(.usedMicroCents))
         resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
      }

      private static func microCents(_ value: Double?) throws -> Double {
         guard let value, value.isFinite, value >= 0 else {
            throw DecodingError.dataCorrupted(
               DecodingError.Context(
                  codingPath: [], debugDescription: "invalid micro-cents amount"))
         }
         return value
      }

      func limit() -> UsageLimit {
         let percent: Double
         if limitMicroCents == 0 {
            percent = usedMicroCents > 0 ? 100 : 0
         } else {
            percent = min(100, max(0, (usedMicroCents / limitMicroCents * 100).rounded()))
         }
         // A null resetsAt means no active window — show "—", never the
         // subscription period end (endsAt), which is ~30 days out and would
         // put "resets in 30 days" on the 5-hour gauge.
         return UsageLimit(
            utilization: percent, resetAt: resetsAt.flatMap(OpenCodeGoUsageResponse.Window.parseDate))
      }
   }

   struct Meters: Decodable, Sendable {
      let fiveHour: Meter
      let week: Meter
      let month: Meter?
   }

   struct Access: Decodable, Sendable {
      let meters: Meters
      let endsAt: String?
   }

   /// Missing when the console account has no Go subscription.
   let access: Access?

   func snapshot(accountName: String?) throws -> UsageSnapshot {
      guard let access else { throw OpenCodeGoStatusError.notSubscribed }
      return UsageSnapshot(
         session: access.meters.fiveHour.limit(),
         weekly: access.meters.week.limit(),
         sonnet: nil,
         lastUpdated: Date(),
         orgName: accountName
      )
   }
}

private extension KeyedDecodingContainer {
   /// Micro-cents arrive as decimal strings; numbers are accepted too.
   func decodeIfPresentAsDoubleOrString(_ key: Key) throws -> Double? {
      if let number = try? decodeIfPresent(Double.self, forKey: key) { return number }
      guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
      return Double(raw)
   }
}
