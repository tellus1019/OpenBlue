// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OpenBlue",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "OpenBlue", targets: ["OpenBlue"])],
  targets: [
    .target(
      name: "AudioCore", publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"), .linkedFramework("Accelerate")]),
    .target(name: "Settings", dependencies: ["AudioCore"]),
    .target(name: "AudioClients"),
    .target(name: "AudioLifecycle"),
    .executableTarget(name: "OpenBlue", dependencies: ["AudioCore", "Settings", "AudioClients", "AudioLifecycle"]),
    .testTarget(name: "AudioClientsTests", dependencies: ["AudioClients"]),
    .testTarget(name: "AudioLifecycleTests", dependencies: ["AudioLifecycle"]),
    .testTarget(name: "SettingsTests", dependencies: ["Settings"]),
  ]
)
