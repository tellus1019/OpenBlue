import AudioCore
import Foundation
import OSLog

private let settingsLog = Logger(subsystem: "org.openblue.app", category: "Settings")

public struct AudioSettings: Codable, Equatable, Sendable {
  public var schemaVersion = 2
  public var gainDB: Float = 0
  public var bypass = false
  public var deviceUID: String?
  public var processing = ProcessingParameter.defaults
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, gainDB, bypass, deviceUID, processing
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .schemaVersion)
    guard version == 1 || version == 2 else { throw SettingsError.unsupportedVersion(version) }
    gainDB = try c.decode(Float.self, forKey: .gainDB)
    bypass = try c.decode(Bool.self, forKey: .bypass)
    deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
    processing = version == 1
      ? ProcessingParameter.defaults : try c.decode([String: Float].self, forKey: .processing)
    schemaVersion = 2
    try validate()
  }
  public var dspValues: [Float] {
    [gainDB, bypass ? 1 : 0] + ProcessingParameter.stored.map { processing[$0.key] ?? $0.initial }
  }
  public func validate() throws {
    guard schemaVersion == 2 else { throw SettingsError.unsupportedVersion(schemaVersion) }
    guard gainDB.isFinite, (-24...12).contains(gainDB) else { throw SettingsError.invalidGain }
    guard Set(processing.keys) == Set(ProcessingParameter.defaults.keys),
      dspValues.withUnsafeBufferPointer({ ob_parameters_valid($0.baseAddress, UInt32($0.count)) })
    else { throw SettingsError.invalidProcessing }
  }
}
public enum SettingsError: Error, LocalizedError {
  case unsupportedVersion(Int)
  case invalidGain
  case invalidProcessing
  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let version):
      "Settings version \(version) is unsupported. The file has been preserved."
    case .invalidGain: "The saved gain is invalid. The file has been preserved."
    case .invalidProcessing: "Processing settings are incomplete or invalid. The file has been preserved."
    }
  }
}

public struct SettingsStore: Sendable {
  public let url: URL
  public init(url: URL) { self.url = url }
  public var migrationBackupURL: URL { url.appendingPathExtension("schema1-backup") }
  public func load() throws -> AudioSettings {
    guard FileManager.default.fileExists(atPath: url.path) else {
      settingsLog.info("No saved configuration; using deterministic defaults")
      return AudioSettings()
    }
    let settings = try JSONDecoder().decode(AudioSettings.self, from: Data(contentsOf: url))
    try settings.validate()
    settingsLog.info("Configuration loaded as schema 2")
    return settings
  }
  public func save(_ settings: AudioSettings) throws {
    try settings.validate()
    // Refuse to replace an invalid or newer document even if the app loaded earlier.
    var migrated = false
    if FileManager.default.fileExists(atPath: url.path) {
      let original = try Data(contentsOf: url)
      _ = try JSONDecoder().decode(AudioSettings.self, from: original)
      let object = try JSONSerialization.jsonObject(with: original) as? [String: Any]
      if object?["schemaVersion"] as? Int == 1 {
        // Preserve exactly the document being migrated before committing schema 2.
        try original.write(to: migrationBackupURL, options: [.atomic])
        migrated = true
      }
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(settings).write(to: url, options: [.atomic])
    if migrated { settingsLog.info("Configuration migrated from schema 1 to 2; original backed up") }
  }
}
