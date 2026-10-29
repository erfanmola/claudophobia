import AppKit
import SwiftUI

// MARK: - Menu bar label (mini ring gauge)

struct MenuBarLabel: View {
   @ObservedObject var model: AppModel

   var body: some View {
      Image(nsImage: renderedImage)
         .help(helpText)
   }

   private var snapshots: [UsageSnapshot] {
      model.accounts.compactMap { model.snapshots[$0.id] }
   }

   private var helpText: String {
      guard !model.accounts.isEmpty else { return "Claudophobia — not signed in" }
      let summaries = model.accounts.map { account -> String in
         guard let snap = model.snapshots[account.id] else { return "\(account.name): loading" }
         return String(format: "%@: session %d%% · weekly %d%%", account.name,
                       Int(snap.session.utilization.rounded()),
                       Int(snap.weekly.utilization.rounded()))
      }
      return "Claudophobia — " + summaries.joined(separator: " | ")
   }

   private var renderedImage: NSImage {
      let content = HStack(spacing: 2) {
         if snapshots.isEmpty {
            Image(systemName: "circle.grid.2x2.fill")
               .font(.system(size: 15, weight: .medium))
         } else {
            ForEach(Array(snapshots.prefix(3).enumerated()), id: \.offset) { _, snap in
               MiniGauge(progress: snap.session.fraction, level: snap.session.statusLevel, size: 11)
            }
            if snapshots.count > 3 {
               Text("+\(snapshots.count - 3)").font(.system(size: 7, weight: .bold))
            }
         }
      }
      .frame(width: 22, height: 18)
      let renderer = ImageRenderer(content: content)
      renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
      return renderer.nsImage ?? NSImage(size: .zero)
   }
}

// MARK: - Popover

struct MenuBarView: View {
   @EnvironmentObject var model: AppModel
   @State private var showPasteField = false
   @State private var pastedKey = ""

   var body: some View {
      VStack(alignment: .leading, spacing: 10) {
         if model.accounts.isEmpty {
            onboarding
         } else {
            usageContent
         }
      }
      .padding(14)
      .frame(width: 360)
   }

   // MARK: Onboarding

   private var onboarding: some View {
      VStack(spacing: 12) {
         ZStack {
            Circle()
               .fill(Assets.accentGradient)
               .frame(width: 54, height: 54)
            Image(systemName: "sparkles")
               .font(.system(size: 24, weight: .semibold))
               .foregroundStyle(.white)
         }
         .padding(.top, 8)

         VStack(spacing: 4) {
            Text("Claudophobia")
               .font(.system(size: 17, weight: .bold))
            Text(
               "Your Claude quota — session & weekly — in the menu bar and the notch. Never run out mid-thought."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
         }

         Button {
            model.startLogin()
         } label: {
            Label("Sign in with Claude", systemImage: "person.crop.circle.badge.plus")
               .frame(maxWidth: .infinity)
         }
         .buttonStyle(.borderedProminent)
         .tint(Assets.accent)

         if showPasteField {
            SecureField("Paste session key (sk-ant-…)", text: $pastedKey)
               .textFieldStyle(.roundedBorder)
               .font(.system(size: 11))
            HStack {
               Button("Cancel") {
                  showPasteField = false
                  pastedKey = ""
               }
               .controlSize(.small)
               Spacer()
               Button("Add account") {
                  let key = pastedKey
                  pastedKey = ""
                  showPasteField = false
                  Task { await model.completeLogin(sessionKey: key) }
               }
               .controlSize(.small)
               .disabled(pastedKey.isEmpty)
            }
         } else {
            Button("…or paste a session key") {
               showPasteField = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
         }

         if let error = model.loginError {
            Text(error)
               .font(.system(size: 11))
               .foregroundStyle(Assets.statusCritical)
               .multilineTextAlignment(.center)
         }

         Divider()
         footer
      }
   }

   // MARK: Signed-in content

   private var usageContent: some View {
      VStack(alignment: .leading, spacing: 10) {
         HStack {
            Text("All accounts")
               .font(.system(size: 14, weight: .bold))
            Spacer()
            Text("\(model.accounts.count)")
               .font(.system(size: 10, weight: .semibold))
               .foregroundStyle(.secondary)
         }

         ForEach(model.accounts) { account in
            accountRow(account)
         }

         Divider()

         HStack {
            if model.isRefreshing {
               ProgressView().controlSize(.small)
            } else {
               Button {
                  Task { await model.refreshAll() }
               } label: {
                  Image(systemName: "arrow.clockwise")
               }
               .buttonStyle(.plain)
               .help("Refresh now")
            }
            if let last = model.lastRefresh {
               Text(Self.relativeTime(last.timeIntervalSinceNow))
                  .font(.system(size: 10))
                  .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
               Button {
                  model.startLogin()
               } label: {
                  Label("Add account…", systemImage: "plus")
               }
               Toggle(isOn: notchBinding) {
                  Label("Show notch widget", systemImage: "rectangle.3.group")
               }
               Toggle(isOn: launchAtLoginBinding) {
                  Label("Open at startup", systemImage: "power")
               }
            } label: {
               Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
         }

         Divider()
         footer
      }
   }

   private func accountRow(_ account: ClaudeAccount) -> some View {
      HStack(spacing: 10) {
         VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
               Text(account.name)
                  .font(.system(size: 12, weight: .semibold))
                  .lineLimit(1)
            }
            if let error = model.accountErrors[account.id] {
               HStack(spacing: 4) {
                  Text(error)
                     .font(.system(size: 10))
                     .foregroundStyle(Assets.statusCritical)
                  Button("Sign in again") {
                     model.reauthenticate(accountID: account.id)
                  }
                  .buttonStyle(.plain)
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(Assets.accent)
               }
            } else if let snap = model.snapshots[account.id] {
               Text(
                  "Session \(Int(snap.session.utilization.rounded()))% · \(snap.session.resetDescription)"
               )
               .font(.system(size: 10))
               .foregroundStyle(.tertiary)
            } else {
               Text("Waiting for first refresh…")
                  .font(.system(size: 10))
                  .foregroundStyle(.tertiary)
            }
         }
         Spacer()
         if let snap = model.snapshots[account.id] {
            MiniGauge(progress: snap.session.fraction, level: snap.session.statusLevel, size: 18)
            MiniGauge(progress: snap.weekly.fraction, level: snap.weekly.statusLevel, size: 18)
         }
      }
      .padding(10)
      .background(
         RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Assets.cardFill)
      )
   }

   private var footer: some View {
      HStack {
         SettingsLink {
            Label("Settings", systemImage: "gearshape")
               .font(.system(size: 12))
         }
         .buttonStyle(.plain)
         .foregroundStyle(.secondary)

         Spacer()

         Button("Quit") {
            NSApp.terminate(nil)
         }
         .buttonStyle(.plain)
         .font(.system(size: 12))
         .foregroundStyle(.secondary)
      }
   }

   private var notchBinding: Binding<Bool> {
      Binding(
         get: { model.config.settings.notchEnabled },
         set: { newValue in model.updateSettings { $0.notchEnabled = newValue } }
      )
   }

   private var launchAtLoginBinding: Binding<Bool> {
      Binding(
         get: { model.config.settings.launchAtLogin },
         set: { newValue in model.updateSettings { $0.launchAtLogin = newValue } }
      )
   }

   private static func relativeTime(_ interval: TimeInterval) -> String {
      "Updated " + RelativeDateTimeFormatter().localizedString(fromTimeInterval: interval)
   }
}
