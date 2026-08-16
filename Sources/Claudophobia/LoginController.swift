import AppKit
import WebKit

/// Presents an embedded claude.ai login window and harvests the `sessionKey` cookie
/// once the user signs in — no manual cookie digging required.
@MainActor
final class LoginController: NSObject, NSWindowDelegate {
   private var window: NSWindow?
   private let webView: WKWebView
   private let onSessionKey: (String) -> Void
   private var pollTask: Task<Void, Never>?
   private var isComplete = false

   init(onSessionKey: @escaping (String) -> Void) {
      self.onSessionKey = onSessionKey
      let configuration = WKWebViewConfiguration()
      let store = WKWebsiteDataStore.nonPersistent()
      configuration.websiteDataStore = store
      configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
      webView = WKWebView(frame: .zero, configuration: configuration)
      super.init()
   }

   func present() {
      guard window == nil else { return }

      let rect = NSRect(x: 0, y: 0, width: 520, height: 660)
      let win = NSWindow(
         contentRect: rect,
         styleMask: [.titled, .closable],
         backing: .buffered,
         defer: false
      )
      win.title = "Sign in to Claude"
      win.contentView = webView
      win.isReleasedWhenClosed = false
      win.delegate = self
      win.center()
      window = win

      NSApp.activate(ignoringOtherApps: true)
      win.makeKeyAndOrderFront(nil)

      if let url = URL(string: "https://claude.ai") {
         webView.load(URLRequest(url: url))
      }

      pollTask = Task { [weak self] in
         while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let self, !self.isComplete else { return }
            if let key = await self.extractSessionKey() {
               self.complete(with: key)
            }
         }
      }
   }

   func cancel() {
      guard !isComplete else { return }
      isComplete = true
      pollTask?.cancel()
      window?.close()
      window = nil
   }

   private func extractSessionKey() async -> String? {
      let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
      for cookie in cookies where cookie.name == "sessionKey" && cookie.value.hasPrefix("sk-ant-") {
         return cookie.value
      }
      return nil
   }

   private func complete(with key: String) {
      isComplete = true
      pollTask?.cancel()
      window?.close()
      window = nil
      onSessionKey(key)
   }

   // NSWindowDelegate — user closed the window without signing in.
   nonisolated func windowWillClose(_ notification: Notification) {
      Task { @MainActor in
         guard !self.isComplete else { return }
         self.isComplete = true
         self.pollTask?.cancel()
         self.window = nil
      }
   }
}
