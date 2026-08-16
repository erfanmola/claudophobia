import Foundation

// MARK: - Threshold logic (pure, unit-testable)

enum ThresholdKind: String, Sendable {
   case session
   case weekly

   var title: String {
      switch self {
      case .session: return "session"
      case .weekly: return "weekly"
      }
   }
}

enum ThresholdEvent: Equatable, Sendable {
   /// Utilization crossed the configured warning threshold.
   case crossed(kind: ThresholdKind, percentage: Double, resetAt: Date?)
   /// Utilization dropped back to ~0 — the quota window refreshed.
   case refreshed(kind: ThresholdKind)
}

struct ThresholdEvaluation: Equatable, Sendable {
   var events: [ThresholdEvent] = []
   var armed: [String: Bool] = [:]
}

/// Decides when to fire threshold notifications (rising edge with hysteresis).
enum ThresholdEvaluator {
   /// A crossing is considered "used up" once usage drops this far below the threshold.
   static let hysteresis: Double = 3

   static func evaluate(
      accountID: String,
      snapshot: UsageSnapshot,
      previous: UsageSnapshot?,
      settings: AppSettings,
      armed: [String: Bool]
   ) -> ThresholdEvaluation {
      var evaluation = ThresholdEvaluation()
      evaluation.armed = armed

      evaluateLimit(
         kind: .session,
         limit: snapshot.session,
         threshold: settings.sessionWarningThreshold,
         accountID: accountID,
         evaluation: &evaluation
      )
      evaluateLimit(
         kind: .weekly,
         limit: snapshot.weekly,
         threshold: settings.weeklyWarningThreshold,
         accountID: accountID,
         evaluation: &evaluation
      )

      if settings.notifyOnReset {
         detectRefresh(
            kind: .session, limit: snapshot.session, previous: previous?.session,
            evaluation: &evaluation)
         detectRefresh(
            kind: .weekly, limit: snapshot.weekly, previous: previous?.weekly,
            evaluation: &evaluation)
      }

      return evaluation
   }

   private static func evaluateLimit(
      kind: ThresholdKind,
      limit: UsageLimit,
      threshold: Double,
      accountID: String,
      evaluation: inout ThresholdEvaluation
   ) {
      let key = "\(accountID).\(kind.rawValue)"
      if limit.utilization >= threshold {
         if evaluation.armed[key] != true {
            evaluation.events.append(
               .crossed(kind: kind, percentage: limit.utilization, resetAt: limit.resetAt))
         }
         evaluation.armed[key] = true
      } else if limit.utilization < threshold - hysteresis {
         evaluation.armed[key] = false
      }
   }

   private static func detectRefresh(
      kind: ThresholdKind,
      limit: UsageLimit,
      previous: UsageLimit?,
      evaluation: inout ThresholdEvaluation
   ) {
      guard let previous else { return }
      // Dropped from meaningful usage to ~nothing ⇒ the window reset.
      if previous.utilization > 30, limit.utilization <= 5 {
         evaluation.events.append(.refreshed(kind: kind))
      }
   }
}
