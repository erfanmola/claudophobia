import Foundation
import SwiftUI

// MARK: - Usage

/// A single usage limit (5-hour session or 7-day weekly window).
struct UsageLimit: Codable, Equatable, Sendable {
   /// Utilization percentage (0-100+, can exceed 100).
   var utilization: Double
   /// When the window resets (best-effort from server, falls back to a default window).
   var resetAt: Date?

   /// Clamped 0...1 for drawing.
   var fraction: Double { min(max(utilization, 0), 100) / 100 }

   var isExceeded: Bool { utilization >= 100 }

   var statusLevel: UsageLevel {
      switch utilization {
      case ..<50: return .safe
      case ..<80: return .warning
      default: return .critical
      }
   }

   /// Short human-readable reset countdown, e.g. "resets in 3h 20m".
   var resetDescription: String {
      guard let resetAt else { return "—" }
      let remaining = resetAt.timeIntervalSinceNow
      guard remaining > 0 else { return "resetting…" }

      let minute: TimeInterval = 60
      let hour: TimeInterval = 3600
      let day: TimeInterval = 86400

      if remaining < hour {
         return "resets in \(max(1, Int(ceil(remaining / minute))))m"
      }
      if remaining < day {
         return "resets in \(Int(ceil(remaining / hour)))h"
      }
      let hours = Int(ceil(remaining / hour))
      let days = hours / 24
      let remHours = hours % 24
      return remHours == 0 ? "resets in \(days)d" : "resets in \(days)d \(remHours)h"
   }
}

/// Visual status band for a limit.
enum UsageLevel: String, Sendable {
   case safe
   case warning
   case critical

   var color: Color {
      switch self {
      case .safe: return Assets.statusSafe
      case .warning: return Assets.statusWarning
      case .critical: return Assets.statusCritical
      }
   }
}

/// A full usage snapshot for one account.
struct UsageSnapshot: Equatable, Sendable {
   var session: UsageLimit
   var weekly: UsageLimit
   var sonnet: UsageLimit?
   var lastUpdated: Date
   var orgName: String?
}

/// A point in a usage history series (for the notch sparkline).
struct UsageSample: Codable, Equatable, Sendable {
   var date: Date
   var session: Double
   var weekly: Double
}

// MARK: - Account

/// A configured Claude account. The session key itself is stored in the Keychain
/// keyed by `id` — never persisted in the config file.
struct ClaudeAccount: Codable, Identifiable, Equatable, Sendable {
   var id: String
   var name: String
   var email: String?
   var orgID: String?
   var orgName: String?
   var createdAt: Date

   init(name: String, email: String? = nil, orgID: String?, orgName: String?) {
      self.id = UUID().uuidString
      self.name = name
      self.email = email
      self.orgID = orgID
      self.orgName = orgName
      self.createdAt = Date()
   }
}

// MARK: - Settings

struct AppSettings: Codable, Equatable, Sendable {
   /// How often to poll claude.ai for usage.
   var pollInterval: TimeInterval = 120
   /// Register as a login item. On by default — the whole point is watching
   /// your quota before you burn it.
   var launchAtLogin: Bool = true

   // Notch
   var notchEnabled: Bool = true
   /// Width of the camera housing; pill hugs this.
   var notchWidth: Double = 128
   var autoExpandNotchOnHover: Bool = true

   // Notifications
   var notifyEnabled: Bool = true
   var soundEnabled: Bool = true
   var notifyOnReset: Bool = true
   /// Session utilization percentage that triggers a warning (default 80%).
   var sessionWarningThreshold: Double = 80
   /// Weekly utilization percentage that triggers a warning (default 80%).
   var weeklyWarningThreshold: Double = 80

   var thresholds: (session: Double, weekly: Double) {
      (sessionWarningThreshold, weeklyWarningThreshold)
   }

   private enum CodingKeys: String, CodingKey {
      case pollInterval
      case launchAtLogin
      case notchEnabled
      case notchWidth
      case autoExpandNotchOnHover
      case notifyEnabled
      case soundEnabled
      case notifyOnReset
      case sessionWarningThreshold
      case weeklyWarningThreshold
   }

   // Decode leniently: configs written by older builds may miss newer keys.
   init() {}

   init(
      pollInterval: TimeInterval = 120,
      launchAtLogin: Bool = true,
      notchEnabled: Bool = true,
      notchWidth: Double = 128,
      autoExpandNotchOnHover: Bool = true,
      notifyEnabled: Bool = true,
      soundEnabled: Bool = true,
      notifyOnReset: Bool = true,
      sessionWarningThreshold: Double = 80,
      weeklyWarningThreshold: Double = 80
   ) {
      self.pollInterval = pollInterval
      self.launchAtLogin = launchAtLogin
      self.notchEnabled = notchEnabled
      self.notchWidth = notchWidth
      self.autoExpandNotchOnHover = autoExpandNotchOnHover
      self.notifyEnabled = notifyEnabled
      self.soundEnabled = soundEnabled
      self.notifyOnReset = notifyOnReset
      self.sessionWarningThreshold = sessionWarningThreshold
      self.weeklyWarningThreshold = weeklyWarningThreshold
   }

   init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      pollInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? 120
      launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
      notchEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchEnabled) ?? true
      notchWidth = try c.decodeIfPresent(Double.self, forKey: .notchWidth) ?? 128
      autoExpandNotchOnHover =
         try c.decodeIfPresent(Bool.self, forKey: .autoExpandNotchOnHover) ?? true
      notifyEnabled = try c.decodeIfPresent(Bool.self, forKey: .notifyEnabled) ?? true
      soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
      notifyOnReset = try c.decodeIfPresent(Bool.self, forKey: .notifyOnReset) ?? true
      sessionWarningThreshold =
         try c.decodeIfPresent(Double.self, forKey: .sessionWarningThreshold) ?? 80
      weeklyWarningThreshold =
         try c.decodeIfPresent(Double.self, forKey: .weeklyWarningThreshold) ?? 80
   }

   func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(pollInterval, forKey: .pollInterval)
      try c.encode(launchAtLogin, forKey: .launchAtLogin)
      try c.encode(notchEnabled, forKey: .notchEnabled)
      try c.encode(notchWidth, forKey: .notchWidth)
      try c.encode(autoExpandNotchOnHover, forKey: .autoExpandNotchOnHover)
      try c.encode(notifyEnabled, forKey: .notifyEnabled)
      try c.encode(soundEnabled, forKey: .soundEnabled)
      try c.encode(notifyOnReset, forKey: .notifyOnReset)
      try c.encode(sessionWarningThreshold, forKey: .sessionWarningThreshold)
      try c.encode(weeklyWarningThreshold, forKey: .weeklyWarningThreshold)
   }
}

/// Everything we persist to disk. Session keys live in the Keychain.
struct AppConfig: Codable, Equatable {
   var accounts: [ClaudeAccount] = []
   var activeAccountID: String?
   var settings: AppSettings = AppSettings()
   /// "accountID.limitKind" -> has a threshold notification been fired for the current crossing.
   var armedThresholds: [String: Bool] = [:]
   /// Per-account rolling usage history, capped per account.
   var history: [String: [UsageSample]] = [:]

   /// Max history points kept per account.
   static let maxHistoryPerAccount = 200

   init() {}

   // Custom decoding so new fields get defaults for configs written by older builds.
   init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      accounts = try c.decodeIfPresent([ClaudeAccount].self, forKey: .accounts) ?? []
      activeAccountID = try c.decodeIfPresent(String.self, forKey: .activeAccountID)
      settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
      armedThresholds = try c.decodeIfPresent([String: Bool].self, forKey: .armedThresholds) ?? [:]
      history = try c.decodeIfPresent([String: [UsageSample]].self, forKey: .history) ?? [:]
   }
}
