// swift-tools-version: 6.0
import PackageDescription

let package = Package(
   name: "Claudophobia",
   platforms: [
      .macOS(.v14)
   ],
   products: [
      .executable(name: "Claudophobia", targets: ["Claudophobia"])
   ],
   targets: [
      .executableTarget(
         name: "Claudophobia",
         path: "Sources/Claudophobia"
      ),
      .testTarget(
         name: "ClaudophobiaTests",
         dependencies: ["Claudophobia"],
         path: "Tests/ClaudophobiaTests"
      ),
   ]
)

// Swift 5 language mode: keeps the codebase readable while running on the
// Swift 6 toolchain.
package.swiftLanguageModes = [.v5]
