import XCTest
@testable import Settings

final class AdvancedNRSettingsTests: XCTestCase {
  func testLegacySchemaFourRetainsValuesAndSelectsStandard() throws {
    var settings = AudioSettings()
    settings.gainDB = -3.5
    let original = settings
    let data = try JSONEncoder().encode(settings)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "factoryNoiseReductionModes")
    var presets = try XCTUnwrap(object["userPresets"] as? [[String: Any]])
    presets[0].removeValue(forKey: "noiseReductionMode")
    presets[0].removeValue(forKey: "advancedReductionDB")
    object["userPresets"] = presets
    let restored = try JSONDecoder().decode(AudioSettings.self, from: JSONSerialization.data(withJSONObject: object))
    try restored.validate()
    XCTAssertEqual(restored, original)
    XCTAssertEqual(restored.noiseReductionMode, .standard)
  }

  func testAdvancedCopyPersistenceAndDuplication() throws {
    var settings = AudioSettings()
    var factory = settings.selectedPreset
    settings.noiseReductionMode = .advanced
    factory.noiseReductionMode = .advanced
    settings.advancedReductionDB = 24
    XCTAssertFalse(settings.isFactorySelected)
    XCTAssertEqual(settings.selectedPreset.processing, factory.processing)
    XCTAssertEqual(settings.presets.first { $0.id == factory.id }, factory)
    try settings.createPreset(named: "Advanced duplicate", duplicatingSelected: true)
    XCTAssertEqual(settings.noiseReductionMode, .advanced)
    XCTAssertEqual(settings.advancedReductionDB, 24)
    let restored = try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(settings))
    try restored.validate()
    XCTAssertEqual(restored, settings)
    try settings.selectPreset(factory.id)
    XCTAssertEqual(settings.noiseReductionMode, .advanced)
    XCTAssertEqual(settings.selectedPreset, factory)
  }

  func testFactoryModeSwitchesPreserveBothParameterSetsWithoutCopies() throws {
    var settings = AudioSettings()
    let originals = FactoryPresets.all.map(\.preset)
    for factory in FactoryPresets.all {
      try settings.selectPreset(factory.preset.id)
      let original = settings.selectedPreset
      for mode: NoiseReductionMode in [.advanced, .standard, .advanced] {
        settings.noiseReductionMode = mode
        XCTAssertEqual(settings.selection, .factory(factory.id))
        XCTAssertTrue(settings.userPresets.isEmpty)
        XCTAssertEqual(settings.selectedPresetID, original.id)
        XCTAssertEqual(settings.dspValues, original.dspValues)
        XCTAssertEqual(settings.advancedReductionDB, original.advancedReductionDB)
        XCTAssertEqual(settings.noiseReductionMode, mode)
        XCTAssertEqual(settings.presets.first { $0.id == original.id }, settings.selectedPreset)
      }
      // Control bindings may write their current values without an edit.
      let gain = settings.gainDB, processing = settings.processing
      let bypass = settings.bypass, reduction = settings.advancedReductionDB
      settings.gainDB = gain; settings.processing = processing
      settings.bypass = bypass; settings.advancedReductionDB = reduction
      XCTAssertTrue(settings.userPresets.isEmpty)
    }
    XCTAssertEqual(FactoryPresets.all.map(\.preset), originals)
    let flat = try XCTUnwrap(FactoryPresets.all.first { $0.id == "flat" })
    try settings.selectPreset(flat.preset.id)
    XCTAssertEqual(settings.processing["noiseReductionEnabled"], 0)
    settings.processing["noiseReductionEnabled"] = 1
    XCTAssertEqual(settings.userPresets.count, 1)
    XCTAssertEqual(settings.noiseReductionMode, .advanced)
    let copyID = settings.selectedPresetID
    settings.noiseReductionMode = .standard
    settings.noiseReductionMode = .advanced
    XCTAssertEqual(settings.selectedPresetID, copyID)
    XCTAssertEqual(settings.userPresets.count, 1)
  }

  func testModeChoicesPersistPerFactoryAndInBackup() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    var settings = AudioSettings()
    let first = settings.selectedPresetID
    settings.noiseReductionMode = .advanced
    let second = try XCTUnwrap(FactoryPresets.all.first { $0.preset.id != first }).preset.id
    try settings.selectPreset(second)
    XCTAssertEqual(settings.noiseReductionMode, .standard)
    try store.save(settings)
    settings = try store.load()
    try settings.selectPreset(first)
    XCTAssertEqual(settings.noiseReductionMode, .advanced)
    XCTAssertTrue(settings.userPresets.isEmpty)
    try settings.createPreset(named: "Advanced factory duplicate", duplicatingSelected: true)
    XCTAssertEqual(settings.noiseReductionMode, .advanced)
    XCTAssertEqual(settings.advancedReductionDB, 40)
    settings.advancedReductionDB = 24
    settings.processing["noiseReductionRange"] = 9
    let user = settings.selectedPreset
    settings.noiseReductionMode = .standard
    XCTAssertEqual(settings.processing["noiseReductionRange"], 9)
    settings.noiseReductionMode = .advanced
    XCTAssertEqual(settings.selectedPreset, user)
    let backup = folder.appendingPathComponent("backup.json")
    try store.exportBackup(settings, to: backup)
    try store.restore(store.readBackup(from: backup))
    XCTAssertEqual(try store.load(), settings)
    try settings.selectPreset(first)
    settings.noiseReductionMode = .standard
    XCTAssertTrue(settings.factoryNoiseReductionModes.isEmpty)
    XCTAssertEqual(settings.userPresets, [user])
  }

  func testExistingAdvancedUserAndFactoryDefaultsSurviveMissingModeChoices() throws {
    var settings = AudioSettings()
    settings.gainDB = -2
    settings.noiseReductionMode = .advanced
    settings.advancedReductionDB = 27
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    object.removeValue(forKey: "factoryNoiseReductionModes")
    var restored = try JSONDecoder().decode(AudioSettings.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(restored, settings)
    for factory in FactoryPresets.all {
      try restored.selectPreset(factory.preset.id)
      XCTAssertEqual(restored.selectedPreset, factory.preset)
    }
  }

  func testInvalidFactoryModeChoicesDoNotOverwriteSettings() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    for choice in [["unknown-preset": "advanced"], [FactoryPresets.initialID: "unknown-mode"]] {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AudioSettings())) as? [String: Any])
      object["factoryNoiseReductionModes"] = choice
      let original = try JSONSerialization.data(withJSONObject: object)
      try original.write(to: store.url)
      XCTAssertThrowsError(try store.load())
      XCTAssertThrowsError(try store.save(AudioSettings()))
      XCTAssertEqual(try Data(contentsOf: store.url), original)
    }
  }

  func testInvalidAdvancedParametersAreRejected() throws {
    var settings = AudioSettings()
    for value: Float in [-1, 61, .infinity, .nan] {
      settings.advancedReductionDB = value
      XCTAssertThrowsError(try settings.validate())
    }
    settings.advancedReductionDB = 40
    var json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    json = json.replacingOccurrences(of: "\"standard\"", with: "\"unknown\"")
    XCTAssertThrowsError(try JSONDecoder().decode(AudioSettings.self, from: Data(json.utf8)))
  }
}
