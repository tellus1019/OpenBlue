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
    .target(name: "AudioClients"),
    .executableTarget(name: "OpenBlue", dependencies: ["AudioCore", "Settings", "AudioClients"]),
    .testTarget(name: "AudioClientsTests", dependencies: ["AudioClients"]),
    .testTarget(name: "SettingsTests", dependencies: ["Settings"]),
  ]
)
