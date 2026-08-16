import AppKit
import SwiftUI

struct SettingsView: View {
   @EnvironmentObject var model: AppModel

   var body: some View {
      TabView {
         generalTab
            .tabItem { Label("General", systemImage: "slider.horizontal.3") }
         accountsTab
            .tabItem { Label("Accounts", systemImage: "person.2") }
         notificationsTab
            .tabItem { Label("Notifications", systemImage: "bell") }
         aboutTab
            .tabItem { Label("About", systemImage: "info.circle") }
      }
      .frame(width: 520, height: 470)
      .padding(18)
   }

   // MARK: General

   private var generalTab: some View {
      Form {
         Section("Tracking") {
            Picker("Update interval", selection: intervalBinding) {
               Text("30 seconds").tag(30.0)
               Text("1 minute").tag(60.0)
               Text("2 minutes").tag(120.0)
               Text("5 minutes").tag(300.0)
               Text("10 minutes").tag(600.0)
               Text("30 minutes").tag(1800.0)
            }
            Toggle("Launch at login", isOn: launchBinding)
            Text("Opens Claudophobia when you log in. Requires the app to be in /Applications.")
               .font(.caption)
               .foregroundStyle(.tertiary)
         }

         Section("Notch") {
            Toggle("Enable notch widget", isOn: notchEnabledBinding)
            VStack(alignment: .leading) {
               Slider(value: notchWidthBinding, in: 120...220, step: 5)
               HStack {
                  Text("Notch width")
                     .font(.caption)
                     .foregroundStyle(.secondary)
                  Spacer()
                  Text("\(Int(model.config.settings.notchWidth)) pt")
                     .font(.caption.monospacedDigit())
                     .foregroundStyle(.secondary)
               }
            }
            Toggle("Expand on hover", isOn: autoExpandBinding)
            Button("Preview notch") {
               NotchController.shared.preview()
            }
            Button("Clear usage history") {
               model.resetHistory()
            }
         }
      }
      .formStyle(.grouped)
   }

   // MARK: Accounts

   private var accountsTab: some View {
      VStack(spacing: 12) {
         if model.accounts.isEmpty {
            VStack(spacing: 10) {
               Image(systemName: "person.crop.circle.badge.plus")
                  .font(.system(size: 30))
                  .foregroundStyle(Assets.accent)
               Text("No accounts yet")
                  .font(.headline)
               Text("Sign in with Claude, or paste a session key from your browser.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
         } else {
            List {
               ForEach(model.accounts) { account in
                  accountSettingsRow(account)
               }
            }
         }

         HStack {
            Button {
               model.startLogin()
            } label: {
               Label("Sign in with Claude", systemImage: "person.crop.circle.badge.plus")
            }
            Spacer()
            Button("Paste session key…") {
               NSPasteboard.general.clearContents()
               showPasteAlert = true
            }
         }
      }
      .alert("Paste session key", isPresented: $showPasteAlert) {
         SecureField("sk-ant-…", text: $pastedKey)
         Button("Add") {
            let key = pastedKey
            pastedKey = ""
            Task { await model.completeLogin(sessionKey: key) }
         }
         Button("Cancel", role: .cancel) { pastedKey = "" }
      } message: {
         Text("Copy the `sessionKey` cookie value from claude.ai (see README) and paste it here.")
      }
   }

   @State private var showPasteAlert = false
   @State private var pastedKey = ""

   private func accountSettingsRow(_ account: ClaudeAccount) -> some View {
      HStack(spacing: 10) {
         Button {
            model.setActive(id: account.id)
         } label: {
            Image(
               systemName: model.activeAccount?.id == account.id
                  ? "checkmark.circle.fill" : "circle"
            )
            .foregroundStyle(model.activeAccount?.id == account.id ? Assets.accent : .secondary)
         }
         .buttonStyle(.plain)
         .help("Make active")

         TextField(
            "Account name",
            text: Binding(
               get: { account.name },
               set: { model.renameAccount(id: account.id, to: $0) }
            )
         )
         .textFieldStyle(.roundedBorder)
         .frame(width: 180)

         Spacer()

         Button("Sign in again") {
            model.reauthenticate(accountID: account.id)
         }
         .controlSize(.small)

         Button(role: .destructive) {
            model.removeAccount(id: account.id)
         } label: {
            Image(systemName: "trash")
         }
         .controlSize(.small)
         .help("Remove account")
      }
      .padding(.vertical, 2)
   }

   // MARK: Notifications

   private var notificationsTab: some View {
      Form {
         Section("Alerts") {
            Toggle("Enable notifications", isOn: notifyEnabledBinding)
            Toggle("Sound (ding)", isOn: soundEnabledBinding)
            Toggle("Notify when a quota refreshes", isOn: notifyOnResetBinding)
            Button("Play test ding") {
               SoundPlayer.shared.playDing()
            }
         }

         Section("Thresholds — warn me at") {
            VStack(alignment: .leading) {
               Slider(value: sessionThresholdBinding, in: 10...100, step: 5)
               HStack {
                  Text("Session (5-hour) limit")
                     .font(.caption)
                     .foregroundStyle(.secondary)
                  Spacer()
                  Text("\(Int(model.config.settings.sessionWarningThreshold))%")
                     .font(.caption.monospacedDigit())
                     .foregroundStyle(.secondary)
               }
            }
            VStack(alignment: .leading) {
               Slider(value: weeklyThresholdBinding, in: 10...100, step: 5)
               HStack {
                  Text("Weekly (7-day) limit")
                     .font(.caption)
                     .foregroundStyle(.secondary)
                  Spacer()
                  Text("\(Int(model.config.settings.weeklyWarningThreshold))%")
                     .font(.caption.monospacedDigit())
                     .foregroundStyle(.secondary)
               }
            }
            Text(
               "You get one banner per crossing; the notification re-arms once usage drops below the threshold again."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
         }
      }
      .formStyle(.grouped)
   }

   // MARK: About

   private var aboutTab: some View {
      VStack(spacing: 14) {
         ZStack {
            Circle()
               .fill(Assets.accentGradient)
               .frame(width: 72, height: 72)
            Image(systemName: "sparkles")
               .font(.system(size: 30, weight: .semibold))
               .foregroundStyle(.white)
         }
         .padding(.top, 16)

         Text("Claudophobia")
            .font(.system(size: 20, weight: .bold))
         Text(
            "Claude usage at a glance — session & weekly quotas in your menu bar and the notch, with warning bells before you run out."
         )
         .font(.caption)
         .foregroundStyle(.secondary)
         .multilineTextAlignment(.center)
         .frame(maxWidth: 340)

         VStack(spacing: 4) {
            Text("Version \(versionString)")
               .font(.caption)
               .foregroundStyle(.tertiary)
            Text(
               "Uses the unofficial claude.ai consumer API. Session keys are stored in your Keychain."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
         }

         Spacer()
      }
      .frame(maxWidth: .infinity)
   }

   private var versionString: String {
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
   }

   // MARK: Bindings

   private func settingBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
      Binding(
         get: { model.config.settings[keyPath: keyPath] },
         set: { value in
            model.updateSettings { $0[keyPath: keyPath] = value }
         }
      )
   }

   private var intervalBinding: Binding<TimeInterval> { settingBinding(\.pollInterval) }
   private var launchBinding: Binding<Bool> { settingBinding(\.launchAtLogin) }
   private var notchEnabledBinding: Binding<Bool> { settingBinding(\.notchEnabled) }
   private var notchWidthBinding: Binding<Double> { settingBinding(\.notchWidth) }
   private var autoExpandBinding: Binding<Bool> { settingBinding(\.autoExpandNotchOnHover) }
   private var notifyEnabledBinding: Binding<Bool> { settingBinding(\.notifyEnabled) }
   private var soundEnabledBinding: Binding<Bool> { settingBinding(\.soundEnabled) }
   private var notifyOnResetBinding: Binding<Bool> { settingBinding(\.notifyOnReset) }
   private var sessionThresholdBinding: Binding<Double> {
      settingBinding(\.sessionWarningThreshold)
   }
   private var weeklyThresholdBinding: Binding<Double> { settingBinding(\.weeklyWarningThreshold) }
}
