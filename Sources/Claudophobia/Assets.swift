import SwiftUI

/// App-wide palette. Brand accent is Claude's warm terracotta; everything else
/// uses adaptive system colors so the UI looks native in both light and dark
/// appearances.
enum Assets {
   /// Claudophobia / Claude brand accent.
   static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)
   static let accentGradient = LinearGradient(
      colors: [
         Color(red: 0.93, green: 0.55, blue: 0.38), Color(red: 0.78, green: 0.38, blue: 0.29),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
   )

   /// Usage-series accents (session amber, weekly violet).
   static let sessionAccent = Color(red: 0.98, green: 0.66, blue: 0.35)
   static let weeklyAccent = Color(red: 0.62, green: 0.48, blue: 0.95)

   /// Status colors — system values adapt to light/dark.
   static let statusSafe = Color(nsColor: .systemGreen)
   static let statusWarning = Color(nsColor: .systemOrange)
   static let statusCritical = Color(nsColor: .systemRed)

   /// Card fill that follows the system appearance.
   static let cardFill = Color(nsColor: .quaternarySystemFill)
}
