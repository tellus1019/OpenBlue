import AudioCore
import Foundation
import OSLog

private let settingsLog = Logger(subsystem: "org.openblue.app", category: "Settings")

public struct Preset: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var name: String
  public var gainDB: Float = 0
  public var bypass = false
  public var processing = ProcessingParameter.defaults

  public init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
  }
  public var dspValues: [Float] {
    [gainDB, bypass ? 1 : 0] + ProcessingParameter.stored.map { processing[$0.key] ?? $0.initial }
  }
  public func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SettingsError.invalidPresetName
    }
    guard gainDB.isFinite, (-24...12).contains(gainDB) else { throw SettingsError.invalidGain }
    guard Set(processing.keys) == Set(ProcessingParameter.defaults.keys),
      dspValues.withUnsafeBufferPointer({ ob_parameters_valid($0.baseAddress, UInt32($0.count)) })
    else { throw SettingsError.invalidProcessing }
  }
}

public struct AudioSettings: Codable, Equatable, Sendable {
  public var schemaVersion = 3
  public var deviceUID: String?
  public private(set) var presets: [Preset]
  public private(set) var selectedPresetID: UUID
  private static let initialID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

  public init() {
    presets = [Preset(id: Self.initialID, name: "Default")]
    selectedPresetID = Self.initialID
  }
  // Construction and decoding validate this relationship before exposing the value.
  private var selectedIndex: Int { presets.firstIndex { $0.id == selectedPresetID }! }
  public var selectedPreset: Preset { presets[selectedIndex] }
  public var gainDB: Float {
    get { selectedPreset.gainDB }
    set { presets[selectedIndex].gainDB = newValue }
  }
  public var bypass: Bool {
    get { selectedPreset.bypass }
    set { presets[selectedIndex].bypass = newValue }
  }
  public var processing: [String: Float] {
    get { selectedPreset.processing }
    set { presets[selectedIndex].processing = newValue }
  }
  public var dspValues: [Float] { selectedPreset.dspValues }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, deviceUID, presets, selectedPresetID, gainDB, bypass, processing
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .schemaVersion)
    guard (1...3).contains(version) else { throw SettingsError.unsupportedVersion(version) }
    deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
    if version == 3 {
      presets = try c.decode([Preset].self, forKey: .presets)
      selectedPresetID = try c.decode(UUID.self, forKey: .selectedPresetID)
    } else {
      presets[0].name = "Current Settings"
      gainDB = try c.decode(Float.self, forKey: .gainDB)
      bypass = try c.decode(Bool.self, forKey: .bypass)
      processing = version == 1
        ? ProcessingParameter.defaults : try c.decode([String: Float].self, forKey: .processing)
    }
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encodeIfPresent(deviceUID, forKey: .deviceUID)
    try c.encode(presets, forKey: .presets)
    try c.encode(selectedPresetID, forKey: .selectedPresetID)
  }
  public func validate() throws {
    guard schemaVersion == 3 else { throw SettingsError.unsupportedVersion(schemaVersion) }
    guard !presets.isEmpty, Set(presets.map(\.id)).count == presets.count,
      presets.contains(where: { $0.id == selectedPresetID }),
      Set(presets.map { Self.nameKey($0.name) }).count == presets.count
    else { throw SettingsError.invalidPresets }
    for preset in presets { try preset.validate() }
  }
  private static func nameKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
  private func checkedName(_ name: String, excluding id: UUID? = nil) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !presets.contains(where: { $0.id != id && Self.nameKey($0.name) == Self.nameKey(trimmed) })
    else { throw SettingsError.invalidPresetName }
    return trimmed
  }
  public mutating func createPreset(named name: String, duplicatingSelected: Bool = false) throws {
    var preset = Preset(name: try checkedName(name))
    if duplicatingSelected {
      preset.gainDB = gainDB
      preset.bypass = bypass
      preset.processing = processing
    }
    presets.append(preset)
    selectedPresetID = preset.id
  }
  public mutating func renamePreset(to name: String) throws {
    let checked = try checkedName(name, excluding: selectedPresetID)
    presets[selectedIndex].name = checked
  }
  public mutating func selectPreset(_ id: UUID) throws {
    guard presets.contains(where: { $0.id == id }) else { throw SettingsError.invalidPresets }
    selectedPresetID = id
  }
  public mutating func deleteSelectedPreset() throws {
    guard presets.count > 1 else { throw SettingsError.lastPreset }
    presets.remove(at: selectedIndex)
    selectedPresetID = presets[0].id
  }
}

public enum SettingsError: Error, LocalizedError {
  case unsupportedVersion(Int)
  case invalidGain
  case invalidProcessing
  case invalidPresets
  case invalidPresetName
  case lastPreset
  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let version):
      "Settings version \(version) is unsupported. The file has been preserved."
    case .invalidGain: "The saved gain is invalid. The file has been preserved."
    case .invalidProcessing: "Processing settings are incomplete or invalid. The file has been preserved."
    case .invalidPresets: "The preset list or selection is invalid. The file has been preserved."
    case .invalidPresetName: "Enter a nonempty, unique preset name. Names are not case-sensitive."
    case .lastPreset: "Keep at least one preset."
    }
  }
}

public struct SettingsStore: Sendable {
  public let url: URL
  public init(url: URL) { self.url = url }
  public var migrationBackupURL: URL { migrationBackupURL(version: 1) }
  public func migrationBackupURL(version: Int) -> URL {
    url.appendingPathExtension("schema\(version)-backup")
  }
  public func load() throws -> AudioSettings {
    guard FileManager.default.fileExists(atPath: url.path) else {
      settingsLog.info("No saved configuration; using deterministic defaults")
      return AudioSettings()
    }
    let settings = try decode(Data(contentsOf: url))
    settingsLog.info("Configuration loaded as schema 3")
    return settings
  }
  private func decode(_ data: Data) throws -> AudioSettings {
    let settings = try JSONDecoder().decode(AudioSettings.self, from: data)
    try settings.validate()
    return settings
  }
  private func encoded(_ settings: AudioSettings) throws -> Data {
    try settings.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(settings)
  }
  public func save(_ settings: AudioSettings) throws {
    let data = try encoded(settings)
    // Refuse to replace an invalid or newer document even if the app loaded earlier.
    if FileManager.default.fileExists(atPath: url.path) {
      let original = try Data(contentsOf: url)
      _ = try decode(original)
      let object = try JSONSerialization.jsonObject(with: original) as? [String: Any]
      if let version = object?["schemaVersion"] as? Int, version < 3 {
        try original.write(to: migrationBackupURL(version: version), options: [.atomic])
        settingsLog.info("Original schema \(version) configuration backed up before migration")
      }
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
  }
  public func exportBackup(_ settings: AudioSettings, to destination: URL) throws {
    // Export is a copy, never an alternative route around the active store's checks.
    guard destination.standardizedFileURL != url.standardizedFileURL else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    try encoded(settings).write(to: destination, options: [.atomic])
  }
  public func readBackup(from source: URL) throws -> AudioSettings {
    try decode(Data(contentsOf: source))
  }
  // Only the explicit Restore action can replace a damaged or newer active document.
  // Preserve it first at a unique path; any failure leaves the active file untouched.
  @discardableResult
  public func restore(_ settings: AudioSettings) throws -> URL? {
    let replacement = try encoded(settings)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var preserved: URL?
    if FileManager.default.fileExists(atPath: url.path) {
      let backup = url.appendingPathExtension("before-restore-\(UUID().uuidString).json")
      try Data(contentsOf: url).write(to: backup, options: [.withoutOverwriting])
      preserved = backup
    }
    try replacement.write(to: url, options: [.atomic])
    settingsLog.info("Configuration restored after preserving the previous document")
    return preserved
  }
}
