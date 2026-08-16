import AppKit
import SwiftUI

@main
struct ClaudophobiaApp: App {
   @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
   @StateObject private var model = AppModel.shared

   var body: some Scene {
      MenuBarExtra {
         MenuBarView()
            .environmentObject(model)
      } label: {
         MenuBarLabel(model: model)
      }
      .menuBarExtraStyle(.window)

      Settings {
         SettingsView()
            .environmentObject(model)
      }
   }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
   func applicationDidFinishLaunching(_ notification: Notification) {
      NSApp.setActivationPolicy(.accessory)

      Task {
         await AppModel.shared.bootstrap()
         // Debug/testing hook: expand the notch card so dismissal behavior
         // can be verified without the mouse.
         if CommandLine.arguments.contains("--preview-notch") {
            NotchController.shared.preview()
         }
      }
   }

   func applicationWillTerminate(_ notification: Notification) {
      AppModel.shared.shutdown()
   }
}
