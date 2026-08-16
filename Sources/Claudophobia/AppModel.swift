import AppKit
import ServiceManagement
import SwiftUI

/// Central observable state: accounts, snapshots, settings, polling, notifications.
@MainActor
final class AppModel: ObservableObject {
   static let shared = AppModel()

   @Published var config: AppConfig
   @Published var snapshots: [String: UsageSnapshot] = [:]
   @Published var accountErrors: [String: String] = [:]
   @Published var isRefreshing = false
   @Published var lastRefresh: Date?
   @Published var isLoginPresented = false
   @Published var loginError: String?

   private let api = ClaudeAPI()
   private let configStore = ConfigStore.shared
   private let notificationManager = NotificationManager.shared
   private var pollTask: Task<Void, Never>?
   private var tickTask: Task<Void, Never>?
   private var loginController: LoginController?
   private var previousSnapshots: [String: UsageSnapshot] = [:]

   private init() {
      self.config = configStore.load()
   }

   // MARK: - Derived

   var accounts: [ClaudeAccount] { config.accounts }

   var activeAccount: ClaudeAccount? {
      accounts.first { $0.id == config.activeAccountID } ?? accounts.first
   }

   var activeSnapshot: UsageSnapshot? {
      activeAccount.flatMap { snapshots[$0.id] }
   }

   var activeHistory: [UsageSample] {
      activeAccount.flatMap { config.history[$0.id] } ?? []
   }

   // MARK: - Lifecycle

   func bootstrap() async {
      notificationManager.setup()
      // Don't block startup on the notification permission prompt.
      Task { await notificationManager.requestAuthorization() }
      applyLaunchAtLogin(config.settings.launchAtLogin)
      NotchController.shared.update()
      startPolling()
      startTicking()
   }

   func shutdown() {
      pollTask?.cancel()
      tickTask?.cancel()
      loginController?.cancel()
   }

   /// Keeps reset countdowns / relative timestamps fresh between polls.
   private func startTicking() {
      tickTask?.cancel()
      tickTask = Task { [weak self] in
         while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard let self else { return }
            self.tick()
         }
      }
   }

   // MARK: - Polling

   func startPolling() {
      pollTask?.cancel()
      pollTask = Task { [weak self] in
         while !Task.isCancelled {
            guard let self else { return }
            await self.refreshAll()
            try? await Task.sleep(for: .seconds(self.config.settings.pollInterval))
         }
      }
   }

   func refreshAll() async {
      guard !accounts.isEmpty else { return }
      isRefreshing = true
      defer {
         isRefreshing = false
         lastRefresh = Date()
         NotchController.shared.update()
      }

      for account in accounts {
         await refresh(account: account)
      }
   }

   private func refresh(account: ClaudeAccount) async {
      do {
         let key = try KeychainStore.load(account: account.id)
         let sessionKey = try SessionKey(key)

         var orgID = account.orgID
         if orgID == nil {
            let orgs = try await api.organizations(sessionKey: sessionKey.value)
            guard let org = orgs.first else { throw ClaudeAPIError.noOrganizations }
            orgID = org.uuid
            setAccountOrg(id: account.id, orgID: org.uuid, orgName: org.name)
         }
         guard let orgID else { return }

         let usage = try await api.usage(orgID: orgID, sessionKey: sessionKey.value)
         let snapshot = usage.snapshot(orgName: account.orgName)

         let previous = previousSnapshots[account.id]
         previousSnapshots[account.id] = snapshot
         snapshots[account.id] = snapshot
         accountErrors.removeValue(forKey: account.id)
         appendHistory(accountID: account.id, snapshot: snapshot)

         // Threshold notifications (rising edge, armed state persisted).
         let evaluation = ThresholdEvaluator.evaluate(
            accountID: account.id,
            snapshot: snapshot,
            previous: previous,
            settings: config.settings,
            armed: config.armedThresholds
         )
         if !evaluation.events.isEmpty {
            notificationManager.handle(
               events: evaluation.events, account: account, settings: config.settings)
         }
         if evaluation.armed != config.armedThresholds {
            config.armedThresholds = evaluation.armed
            persist()
         }
      } catch ClaudeAPIError.invalidSession {
         accountErrors[account.id] = "Session expired — sign in again."
      } catch ClaudeAPIError.rateLimited {
         accountErrors[account.id] = "Rate limited by Claude — will retry."
      } catch {
         accountErrors[account.id] = error.localizedDescription
      }
   }

   private func appendHistory(accountID: String, snapshot: UsageSnapshot) {
      var series = config.history[accountID] ?? []
      series.append(
         UsageSample(
            date: snapshot.lastUpdated,
            session: snapshot.session.utilization,
            weekly: snapshot.weekly.utilization
         ))
      if series.count > AppConfig.maxHistoryPerAccount {
         series.removeFirst(series.count - AppConfig.maxHistoryPerAccount)
      }
      config.history[accountID] = series
      persist()
   }

   // MARK: - Accounts

   /// Open the in-app web login window. On success creates one account per org.
   func startLogin() {
      guard loginController == nil else { return }
      isLoginPresented = true
      loginError = nil
      let controller = LoginController { [weak self] key in
         Task { @MainActor in
            self?.loginController = nil
            self?.isLoginPresented = false
            await self?.completeLogin(sessionKey: key)
         }
      }
      loginController = controller
      controller.present()
   }

   /// Re-authenticate an existing account (e.g. after session expiry).
   func reauthenticate(accountID: String) {
      guard loginController == nil else { return }
      loginError = nil
      let controller = LoginController { [weak self] key in
         Task { @MainActor in
            self?.loginController = nil
            await self?.replaceSessionKey(key, for: accountID)
         }
      }
      loginController = controller
      controller.present()
   }

   /// Finish login from a pasted session key (no webview).
   func completeLogin(sessionKey raw: String) async {
      do {
         let sessionKey = try SessionKey(raw)
         let orgs = try await api.organizations(sessionKey: sessionKey.value)
         guard !orgs.isEmpty else { throw ClaudeAPIError.noOrganizations }

         for org in orgs {
            let account = ClaudeAccount(
               name: uniqueName(for: org.name), orgID: org.uuid, orgName: org.name)
            try KeychainStore.save(sessionKey.value, account: account.id)
            config.accounts.append(account)
         }
         if config.activeAccountID == nil {
            config.activeAccountID = config.accounts.first?.id
         }
         loginError = nil
         persist()
         await refreshAll()
      } catch {
         loginError = error.localizedDescription
      }
   }

   private func replaceSessionKey(_ raw: String, for accountID: String) async {
      do {
         let sessionKey = try SessionKey(raw)
         try KeychainStore.save(sessionKey.value, account: accountID)
         guard let index = config.accounts.firstIndex(where: { $0.id == accountID }) else { return }
         // Refetch org list so the account points at a live org again.
         let orgs = try await api.organizations(sessionKey: sessionKey.value)
         if let org = orgs.first {
            config.accounts[index].orgID = org.uuid
            config.accounts[index].orgName = org.name
            if config.accounts[index].name.isEmpty || config.accounts[index].name == "Claude" {
               config.accounts[index].name = org.name
            }
         }
         loginError = nil
         persist()
         await refreshAll()
      } catch {
         loginError = error.localizedDescription
      }
   }

   private func uniqueName(for base: String) -> String {
      let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = trimmed.isEmpty ? "Claude" : trimmed
      let taken = Set(config.accounts.map(\.name))
      guard taken.contains(name) else { return name }
      var index = 2
      while taken.contains("\(name) \(index)") { index += 1 }
      return "\(name) \(index)"
   }

   func removeAccount(id: String) {
      config.accounts.removeAll { $0.id == id }
      KeychainStore.delete(account: id)
      snapshots.removeValue(forKey: id)
      previousSnapshots.removeValue(forKey: id)
      accountErrors.removeValue(forKey: id)
      config.history.removeValue(forKey: id)
      config.armedThresholds = config.armedThresholds.filter { !$0.key.hasPrefix(id + ".") }
      if config.activeAccountID == id {
         config.activeAccountID = config.accounts.first?.id
      }
      persist()
   }

   func setActive(id: String) {
      config.activeAccountID = id
      persist()
   }

   func renameAccount(id: String, to newName: String) {
      guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return }
      config.accounts[index].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
      persist()
   }

   private func setAccountOrg(id: String, orgID: String, orgName: String) {
      guard let index = config.accounts.firstIndex(where: { $0.id == id }) else { return }
      config.accounts[index].orgID = orgID
      config.accounts[index].orgName = orgName
      if config.accounts[index].name.isEmpty { config.accounts[index].name = orgName }
      persist()
   }

   // MARK: - Settings

   func updateSettings(_ mutate: (inout AppSettings) -> Void) {
      mutate(&config.settings)
      persist()
      applyLaunchAtLogin(config.settings.launchAtLogin)
      startPolling()
      NotchController.shared.update()
   }

   func resetHistory() {
      config.history = [:]
      config.armedThresholds = [:]
      persist()
   }

   private func applyLaunchAtLogin(_ enabled: Bool) {
      if #available(macOS 13.0, *) {
         do {
            switch enabled {
            case true:
               if SMAppService.mainApp.status != .enabled {
                  try SMAppService.mainApp.register()
               }
            case false:
               if SMAppService.mainApp.status == .enabled {
                  try SMAppService.mainApp.unregister()
               }
            }
         } catch {
            // Not in /Applications or unavailable — non-fatal.
            NSLog("LaunchAtLogin: \(error.localizedDescription)")
         }
      }
   }

   func persist() {
      configStore.save(config)
   }

   // MARK: - Helpers

   /// Fresh countdown tick for the notch display.
   func tick() {
      objectWillChange.send()
   }

   /// Notch expansion state changed; push a view update to notch/menu bar content.
   func notchStateDidChange() {
      objectWillChange.send()
   }
}
