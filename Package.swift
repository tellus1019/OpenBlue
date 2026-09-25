// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OpenBlue",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "OpenBlueCore", targets: ["AudioCore", "Settings", "AudioClients", "AudioLifecycle"])
  ],
  targets: [
    .target(
      name: "AudioCore", publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"), .linkedFramework("Accelerate")]),
    .target(name: "Settings", dependencies: ["AudioCore"]),
    .target(name: "AudioClients"),
    .target(name: "AudioLifecycle"),
    .testTarget(name: "AudioClientsTests", dependencies: ["AudioClients"]),
    .testTarget(name: "AudioLifecycleTests", dependencies: ["AudioLifecycle"]),
    .testTarget(name: "SettingsTests", dependencies: ["Settings"]),
  ]
)
