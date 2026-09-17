import Foundation

public struct AudioSettings: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var gainDB: Float = 0
  public var bypass = false
  public var deviceUID: String?
  public init() {}

  public func validate() throws {
    guard schemaVersion == 1 else { throw SettingsError.unsupportedVersion(schemaVersion) }
    guard gainDB.isFinite, (-24...12).contains(gainDB) else { throw SettingsError.invalidGain }
  }
}
public enum SettingsError: Error, LocalizedError {
  case unsupportedVersion(Int)
  case invalidGain
  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let version):
      "Settings version \(version) is unsupported. The file has been preserved."
    case .invalidGain: "The saved gain is invalid. The file has been preserved."
    }
  }
}

public struct SettingsStore: Sendable {
  public let url: URL
  public init(url: URL) { self.url = url }
  public func load() throws -> AudioSettings {
    guard FileManager.default.fileExists(atPath: url.path) else { return AudioSettings() }
    let settings = try JSONDecoder().decode(AudioSettings.self, from: Data(contentsOf: url))
    try settings.validate()
    return settings
  }
  public func save(_ settings: AudioSettings) throws {
    try settings.validate()
    // Refuse to replace an invalid or newer document even if the app loaded earlier.
    _ = try load()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(settings).write(to: url, options: [.atomic])
  }
}
