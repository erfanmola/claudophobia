import AppKit
import Foundation
import UserNotifications

/// Posts notification-center banners and plays the ding chime.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
   static let shared = NotificationManager()

   private let center = UNUserNotificationCenter.current()

   private override init() {
      super.init()
   }

   func setup() {
      center.delegate = self
   }

   func requestAuthorization() async {
      _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
   }

   func isAuthorized() async -> Bool {
      let settings = await center.notificationSettings()
      return settings.authorizationStatus == .authorized
   }

   /// Turn threshold evaluation results into banners + sounds.
   func handle(events: [ThresholdEvent], account: ClaudeAccount, settings: AppSettings) {
      guard settings.notifyEnabled else { return }
      for event in events {
         switch event {
         case .crossed(let kind, let percentage, let resetAt):
            send(
               title: "\(account.name): \(Int(percentage.rounded()))% of \(kind.title) used",
               body: body(for: kind, resetAt: resetAt),
               soundEnabled: settings.soundEnabled
            )
            if settings.soundEnabled {
               SoundPlayer.shared.playDing()
            }
         case .refreshed(let kind):
            send(
               title: "Quota refreshed — \(account.name)",
               body: "Your \(kind.title) limit is back to full.",
               soundEnabled: settings.soundEnabled
            )
            if settings.soundEnabled {
               SoundPlayer.shared.playReset()
            }
         }
      }
   }

   private func body(for kind: ThresholdKind, resetAt: Date?) -> String {
      switch kind {
      case .session:
         return "Your 5-hour session window is nearly used up."
      case .weekly:
         return "Your 7-day weekly quota is nearly used up."
      }
   }

   private func send(title: String, body: String, soundEnabled: Bool) {
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      if soundEnabled {
         content.sound = .default
      }
      let request = UNNotificationRequest(
         identifier: UUID().uuidString,
         content: content,
         trigger: nil
      )
      center.add(request)
   }

   // Show the banner even while Claudophobia is the frontmost app.
   nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
   ) {
      completionHandler([.banner, .sound])
   }
}
