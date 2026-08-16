import Foundation

/// Loads and saves `AppConfig` as JSON in Application Support.
final class ConfigStore {
   static let shared = ConfigStore()

   private let fileURL: URL
   private let encoder = JSONEncoder()
   private let decoder = JSONDecoder()
   private var cached: AppConfig?
   private let lock = NSLock()

   init(fileURL: URL? = nil) {
      if let fileURL {
         self.fileURL = fileURL
      } else {
         let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudophobia", isDirectory: true)
         try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
         self.fileURL = dir.appendingPathComponent("config.json")
      }
   }

   func load() -> AppConfig {
      lock.lock()
      defer { lock.unlock() }
      if let cached { return cached }
      if let data = try? Data(contentsOf: fileURL),
         let config = try? decoder.decode(AppConfig.self, from: data)
      {
         cached = config
         return config
      }
      let config = AppConfig()
      cached = config
      return config
   }

   func save(_ config: AppConfig) {
      lock.lock()
      defer { lock.unlock() }
      cached = config
      guard let data = try? encoder.encode(config) else { return }
      try? data.write(to: fileURL, options: .atomic)
   }
}
