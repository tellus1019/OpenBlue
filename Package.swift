// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OpenBlue",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "OpenBlue", targets: ["OpenBlue"])],
  targets: [
    .target(
      name: "AudioCore", publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]),
    .target(name: "Settings"),
    .executableTarget(name: "OpenBlue", dependencies: ["AudioCore", "Settings"]),
    .testTarget(name: "SettingsTests", dependencies: ["Settings"]),
  ]
)
