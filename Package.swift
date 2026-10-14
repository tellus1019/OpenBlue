// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OpenBlue",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "OpenBlueCore", targets: ["AudioCore", "NeuralNoiseReduction", "Settings", "AudioClients", "AudioLifecycle"])
  ],
  targets: [
    .target(name: "NeuralNoiseReduction", publicHeadersPath: "include",
      cSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("CoreML"), .linkedFramework("Foundation"), .linkedFramework("Accelerate")]),
    .target(
      name: "AudioCore", publicHeadersPath: "include",
      cSettings: [.define("OB_DIAGNOSTICS", to: "1", .when(configuration: .debug)),
                  .define("OB_DIAGNOSTICS", to: "0", .when(configuration: .release))],
      linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"), .linkedFramework("Accelerate")]),
    .target(name: "Settings", dependencies: ["AudioCore"]),
    .target(name: "AudioClients"),
    .target(name: "AudioLifecycle"),
    .testTarget(name: "AudioClientsTests", dependencies: ["AudioClients"]),
    .testTarget(name: "AudioLifecycleTests", dependencies: ["AudioLifecycle"]),
    .testTarget(name: "SettingsTests", dependencies: ["Settings"]),
  ]
)
