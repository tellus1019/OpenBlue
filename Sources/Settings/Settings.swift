import AudioCore
import Foundation
import OSLog

private let settingsLog = Logger(subsystem: "org.openblue.app", category: "Settings")

public enum NoiseReductionMode: String, Codable, CaseIterable, Sendable {
  case standard, advanced
}

public struct Preset: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var name: String
  public var gainDB: Float = 0
  public var bypass = false
  public var processing = ProcessingParameter.defaults
  public var noiseReductionMode: NoiseReductionMode = .standard
  public var advancedReductionDB: Float = 40
  public var sourceFactoryID: String?
  public var sourceFactoryRevision: Int?

  public init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
  }
  private enum CodingKeys: String, CodingKey {
    case id, name, gainDB, bypass, processing, sourceFactoryID, sourceFactoryRevision
    case noiseReductionMode, advancedReductionDB
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    gainDB = try c.decode(Float.self, forKey: .gainDB)
    bypass = try c.decode(Bool.self, forKey: .bypass)
    processing = try c.decode([String: Float].self, forKey: .processing)
    sourceFactoryID = try c.decodeIfPresent(String.self, forKey: .sourceFactoryID)
    sourceFactoryRevision = try c.decodeIfPresent(Int.self, forKey: .sourceFactoryRevision)
    noiseReductionMode = try c.decodeIfPresent(NoiseReductionMode.self, forKey: .noiseReductionMode) ?? .standard
    advancedReductionDB = try c.decodeIfPresent(Float.self, forKey: .advancedReductionDB) ?? 40
  }
  public var dspValues: [Float] {
    [gainDB, bypass ? 1 : 0] + ProcessingParameter.stored.map { processing[$0.key] ?? $0.initial }
  }
  public func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SettingsError.invalidPresetName
    }
    guard gainDB.isFinite, (-24...12).contains(gainDB) else { throw SettingsError.invalidGain }
    guard advancedReductionDB.isFinite, (0...60).contains(advancedReductionDB)
    else { throw SettingsError.invalidProcessing }
    guard Set(processing.keys) == Set(ProcessingParameter.defaults.keys),
      dspValues.withUnsafeBufferPointer({ ob_parameters_valid($0.baseAddress, UInt32($0.count)) })
    else { throw SettingsError.invalidProcessing }
  }
}

public enum PresetSelection: Codable, Equatable, Sendable {
  case factory(String)
  case user(UUID)
}

public struct AudioSettings: Codable, Equatable, Sendable {
  public var schemaVersion = 4
  public var deviceUID: String?
  public private(set) var userPresets: [Preset] = []
  public private(set) var selection: PresetSelection = .factory(FactoryPresets.initialID)
  public var presets: [Preset] { FactoryPresets.all.map(\.preset) + userPresets }
  public var isFactorySelected: Bool { if case .factory = selection { return true }; return false }
  public var selectedPreset: Preset {
    switch selection {
    case .factory(let id): FactoryPresets.all.first { $0.id == id }!.preset
    case .user(let id): userPresets.first { $0.id == id }!
    }
  }
  public var selectedPresetID: UUID { selectedPreset.id }
  public init() {}

  private mutating func editableIndex() -> Int {
    if case .user(let id) = selection { return userPresets.firstIndex { $0.id == id }! }
    let source = selectedPreset
    var name = source.name + " Copy", number = 2
    while presets.contains(where: { Self.nameKey($0.name) == Self.nameKey(name) }) {
      name = source.name + " Copy \(number)"; number += 1
    }
    var copy = Preset(name: name)
    copy.gainDB = source.gainDB; copy.bypass = source.bypass; copy.processing = source.processing
    copy.noiseReductionMode = source.noiseReductionMode
    copy.advancedReductionDB = source.advancedReductionDB
    if case .factory(let id) = selection {
      copy.sourceFactoryID = id; copy.sourceFactoryRevision = FactoryPresets.revision
    }
    userPresets.append(copy); selection = .user(copy.id)
    return userPresets.count-1
  }
  public var gainDB: Float {
    get { selectedPreset.gainDB }
    set { let index = editableIndex(); userPresets[index].gainDB = newValue }
  }
  public var bypass: Bool {
    get { selectedPreset.bypass }
    set { let index = editableIndex(); userPresets[index].bypass = newValue }
  }
  public var processing: [String: Float] {
    get { selectedPreset.processing }
    set { let index = editableIndex(); userPresets[index].processing = newValue }
  }
  public var noiseReductionMode: NoiseReductionMode {
    get { selectedPreset.noiseReductionMode }
    set { let index = editableIndex(); userPresets[index].noiseReductionMode = newValue }
  }
  public var advancedReductionDB: Float {
    get { selectedPreset.advancedReductionDB }
    set { let index = editableIndex(); userPresets[index].advancedReductionDB = newValue }
  }
  public var dspValues: [Float] { selectedPreset.dspValues }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, deviceUID, userPresets, selection, factoryRevision
    case presets, selectedPresetID, gainDB, bypass, processing
  }
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .schemaVersion)
    guard (1...4).contains(version) else { throw SettingsError.unsupportedVersion(version) }
    deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
    if version == 4 {
      guard try c.decode(Int.self, forKey: .factoryRevision) == FactoryPresets.revision
      else { throw SettingsError.unsupportedCatalog }
      userPresets = try c.decode([Preset].self, forKey: .userPresets)
      selection = try c.decode(PresetSelection.self, forKey: .selection)
    } else if version == 3 {
      let old = try c.decode([LegacySettings.Value].self, forKey: .presets)
      let selected = try c.decode(UUID.self, forKey: .selectedPresetID)
      guard !old.isEmpty, Set(old.map(\.id)).count == old.count,
        old.contains(where: { $0.id == selected }),
        Set(old.map { Self.nameKey($0.name) }).count == old.count,
        old.allSatisfy({ !Self.nameKey($0.name).isEmpty })
      else { throw SettingsError.invalidPresets }
      for preset in old { try LegacySettings.validate(gain: preset.gainDB, processing: preset.processing) }
    } else {
      let gain = try c.decode(Float.self, forKey: .gainDB)
      _ = try c.decode(Bool.self, forKey: .bypass)
      let processing = version == 2 ? try c.decode([String: Float].self, forKey: .processing) : nil
      try LegacySettings.validate(gain: gain, processing: processing)
    }
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encodeIfPresent(deviceUID, forKey: .deviceUID)
    try c.encode(userPresets, forKey: .userPresets)
    try c.encode(selection, forKey: .selection)
    try c.encode(FactoryPresets.revision, forKey: .factoryRevision)
  }
  public func validate() throws {
    guard schemaVersion == 4 else { throw SettingsError.unsupportedVersion(schemaVersion) }
    guard Set(presets.map(\.id)).count == presets.count,
      Set(presets.map { Self.nameKey($0.name) }).count == presets.count
    else { throw SettingsError.invalidPresets }
    switch selection {
    case .factory(let id):
      guard FactoryPresets.all.contains(where: { $0.id == id }) else { throw SettingsError.invalidPresets }
    case .user(let id):
      guard userPresets.contains(where: { $0.id == id }) else { throw SettingsError.invalidPresets }
    }
    for preset in presets {
      try preset.validate()
      guard (preset.sourceFactoryID == nil) == (preset.sourceFactoryRevision == nil),
        preset.sourceFactoryRevision.map({ $0 > 0 }) ?? true
      else { throw SettingsError.invalidPresets }
    }
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
      let source = selectedPreset
      preset.gainDB = gainDB; preset.bypass = bypass; preset.processing = processing
      preset.noiseReductionMode = source.noiseReductionMode
      preset.advancedReductionDB = source.advancedReductionDB
      if case .factory(let id) = selection {
        preset.sourceFactoryID = id; preset.sourceFactoryRevision = FactoryPresets.revision
      } else {
        preset.sourceFactoryID = source.sourceFactoryID
        preset.sourceFactoryRevision = source.sourceFactoryRevision
      }
    }
    userPresets.append(preset); selection = .user(preset.id)
  }
  public mutating func renamePreset(to name: String) throws {
    guard case .user(let id) = selection else { throw SettingsError.fixedPreset }
    let checked = try checkedName(name, excluding: id)
    userPresets[userPresets.firstIndex { $0.id == id }!].name = checked
  }
  public mutating func selectPreset(_ id: UUID) throws {
    if let factory = FactoryPresets.all.first(where: { $0.preset.id == id }) {
      selection = .factory(factory.id)
    } else if userPresets.contains(where: { $0.id == id }) {
      selection = .user(id)
    } else { throw SettingsError.invalidPresets }
  }
  public mutating func deleteSelectedPreset() throws {
    guard case .user(let id) = selection else { throw SettingsError.fixedPreset }
    userPresets.removeAll { $0.id == id }
    selection = .factory(FactoryPresets.initialID)
  }
}

public enum SettingsError: Error, LocalizedError {
  case unsupportedVersion(Int)
  case invalidGain
  case invalidProcessing
  case invalidPresets
  case invalidPresetName
  case fixedPreset
  case unsupportedCatalog
  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let version):
      "Settings version \(version) is unsupported. The file has been preserved."
    case .invalidGain: "The saved gain is invalid. The file has been preserved."
    case .invalidProcessing: "Processing settings are incomplete or invalid. The file has been preserved."
    case .invalidPresets: "The preset list or selection is invalid. The file has been preserved."
    case .invalidPresetName: "Enter a nonempty, unique preset name. Names are not case-sensitive."
    case .fixedPreset: "Factory presets cannot be renamed or deleted. Duplicate one to edit it."
    case .unsupportedCatalog: "This factory catalog revision is unsupported. The file has been preserved."
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
    settingsLog.info("Configuration loaded as schema 4")
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
      if let version = object?["schemaVersion"] as? Int, version < 4 {
        let backup = migrationBackupURL(version: version)
        if FileManager.default.fileExists(atPath: backup.path) {
          if try Data(contentsOf: backup) != original {
            try original.write(to: backup.appendingPathExtension(UUID().uuidString),
                               options: [.withoutOverwriting])
          }
        } else {
          try original.write(to: backup, options: [.withoutOverwriting])
        }
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
