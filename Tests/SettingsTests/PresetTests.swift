import XCTest
@testable import Settings

final class PresetTests: XCTestCase {
  private func withStore(_ body: (SettingsStore) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(SettingsStore(url: folder.appendingPathComponent("settings.json")))
  }

  func testPresetLifecycleAndPersistence() throws {
    try withStore { store in
      var settings = try store.load()
      XCTAssertEqual(settings, AudioSettings())
      settings.deviceUID = "selected-yeti"
      settings.gainDB = -7.5
      settings.bypass = true
      for p in ProcessingParameter.stored { settings.processing[p.key] = p.maximum }
      let first = settings.selectedPreset
      try settings.createPreset(named: " Voice ", duplicatingSelected: true)
      XCTAssertEqual(settings.selectedPreset.name, "Voice")
      XCTAssertEqual(settings.dspValues, first.dspValues)
      let copyID = settings.selectedPresetID
      settings.gainDB = -3
      try settings.renamePreset(to: "Meeting")
      try store.save(settings)
      XCTAssertEqual(try store.load(), settings)
      try settings.selectPreset(first.id)
      XCTAssertEqual(settings.selectedPreset, first)
      try settings.selectPreset(copyID)
      XCTAssertEqual(settings.gainDB, -3)
      XCTAssertEqual(settings.deviceUID, "selected-yeti")
      let before = settings
      XCTAssertThrowsError(try settings.createPreset(named: " meeting "))
      XCTAssertThrowsError(try settings.renamePreset(to: " \n "))
      XCTAssertThrowsError(try settings.selectPreset(UUID()))
      XCTAssertEqual(settings, before)
      try settings.createPreset(named: "Clean")
      XCTAssertEqual(settings.dspValues, Preset(name: "Clean").dspValues)
      try settings.deleteSelectedPreset()
      XCTAssertEqual(settings.selectedPreset.name, "Broadcaster 1")
      try settings.selectPreset(copyID)
      try settings.deleteSelectedPreset()
      XCTAssertThrowsError(try settings.deleteSelectedPreset())
      try store.save(settings)
      XCTAssertEqual(try store.load(), settings)
    }
  }

  func testLegacyDocumentsResetOnlyValidLibraries() throws {
    try withStore { store in
      for version in [1, 2] {
        var object: [String: Any] = [
          "schemaVersion": version, "gainDB": -8.5, "bypass": true, "deviceUID": "legacy-yeti",
        ]
        let processing = LegacySettings.ranges.mapValues { $0.lowerBound }
        if version == 2 { object["processing"] = processing }
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try original.write(to: store.url)
        let migrated = try store.load()
        XCTAssertEqual(migrated.schemaVersion, 4)
        XCTAssertEqual(migrated.presets.count, 12)
        XCTAssertEqual(migrated.selectedPreset.name, "Broadcaster 1")
        XCTAssertEqual(migrated.gainDB, 0)
        XCTAssertFalse(migrated.bypass)
        XCTAssertEqual(migrated.deviceUID, "legacy-yeti")
        XCTAssertEqual(migrated.processing, AudioSettings().processing)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        try store.save(migrated)
        XCTAssertEqual(try Data(contentsOf: store.migrationBackupURL(version: version)), original)
        XCTAssertEqual(try store.load(), migrated)
      }
    }
  }

  func testInvalidPresetDocumentsArePreserved() throws {
    try withStore { store in
      var settings = AudioSettings()
      settings.gainDB = -3
      let valid = try JSONEncoder().encode(settings)
      for corruption in 0..<6 {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var presets = try XCTUnwrap(object["userPresets"] as? [[String: Any]])
        switch corruption {
        case 0: object["schemaVersion"] = 99
        case 1: object["selection"] = ["factory": ["_0": "unknown"]]
        case 2: presets = []
        case 3: presets.append(presets[0])
        case 4: presets[0]["name"] = " "
        default: presets[0]["processing"] = ["invalid": 1]
        }
        object["userPresets"] = presets
        let original = try JSONSerialization.data(withJSONObject: object)
        try original.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(AudioSettings()))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
      }
    }
  }

  func testMigrationKeepsAnExistingDifferentBackup() throws {
    try withStore { store in
      let original = Data("{\"schemaVersion\":1,\"gainDB\":-8,\"bypass\":false}".utf8)
      let earlier = Data("{\"schemaVersion\":1,\"gainDB\":-3,\"bypass\":true}".utf8)
      try original.write(to: store.url)
      try earlier.write(to: store.migrationBackupURL)
      let settings = try store.load()
      try store.save(settings)
      XCTAssertEqual(try Data(contentsOf: store.migrationBackupURL), earlier)
      let files = try FileManager.default.contentsOfDirectory(
        at: store.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
      let extra = try XCTUnwrap(files.first {
        $0.lastPathComponent.hasPrefix("settings.json.schema1-backup.")
      })
      XCTAssertEqual(try Data(contentsOf: extra), original)
      XCTAssertEqual(try store.load(), settings)
    }
  }

  func testFactoryCatalogAndCopyOnFirstEdit() throws {
    var s = AudioSettings()
    XCTAssertEqual(FactoryPresets.all.count, 12)
    XCTAssertEqual(Set(FactoryPresets.all.map(\.id)).count, 12)
    XCTAssertEqual(Set(FactoryPresets.all.map { $0.preset.id }).count, 12)
    XCTAssertEqual(Set(FactoryPresets.all.map { $0.preset.name }), Set([
      "AM", "Bass Boost", "Broadcaster 1", "Broadcaster 2", "Classic Radio", "Crisp and Warm",
      "FM", "High Voice - Loud", "High Voice - Soft", "Low Voice - Loud", "Low Voice - Soft", "Warm and Vintage"
    ]))
    for factory in FactoryPresets.all {
      try factory.preset.validate()
      try s.selectPreset(factory.preset.id)
      XCTAssertTrue(s.isFactorySelected)
      XCTAssertThrowsError(try s.renamePreset(to: "Changed"))
      XCTAssertThrowsError(try s.deleteSelectedPreset())
      XCTAssertEqual(s.selectedPreset, factory.preset)
    }
    let factory = s.selectedPreset
    s.processing["deEsserQ"] = 4
    XCTAssertEqual(s.userPresets.count, 1)
    XCTAssertEqual(s.selectedPreset.sourceFactoryRevision, FactoryPresets.revision)
    let copy = s.selectedPresetID
    s.processing["deEsserQ"] = 5; s.gainDB = -2; s.bypass = true
    XCTAssertEqual(s.selectedPresetID, copy)
    XCTAssertEqual(s.userPresets.count, 1)
    try s.selectPreset(factory.id)
    XCTAssertEqual(s.selectedPreset, factory)
    s.gainDB = -1
    XCTAssertEqual(s.userPresets.count, 2)
    XCTAssertNotEqual(s.userPresets[0].name, s.userPresets[1].name)
    try s.validate()
  }

  func testSchemaThreeResetAndMalformedPreservation() throws {
    try withStore { store in
      let id = UUID().uuidString
      var preset: [String: Any] = ["id": id, "name": "Test", "gainDB": -6,
        "bypass": true, "processing": LegacySettings.ranges.mapValues { $0.lowerBound }]
      for valid in [true, false] {
        if !valid { preset["processing"] = ["noiseFloor": -55] }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 3,
          "deviceUID": "yeti", "selectedPresetID": id, "presets": [preset]])
        try data.write(to: store.url)
        if valid {
          let reset = try store.load()
          XCTAssertEqual(reset.userPresets.count, 0)
          XCTAssertEqual(reset.deviceUID, "yeti")
          XCTAssertEqual(reset.selectedPreset.name, "Broadcaster 1")
          try store.save(reset)
          XCTAssertEqual(try Data(contentsOf: store.migrationBackupURL(version: 3)), data)
        } else {
          XCTAssertThrowsError(try store.load())
          XCTAssertThrowsError(try store.save(AudioSettings()))
          XCTAssertEqual(try Data(contentsOf: store.url), data)
        }
      }
    }
  }

  func testBackupRestorePreservesDamagedOriginalAndRejectsInvalidSource() throws {
    try withStore { store in
      var settings = AudioSettings()
      try settings.createPreset(named: "Meeting")
      settings.gainDB = -9
      try store.save(settings)
      let backup = store.url.deletingLastPathComponent().appendingPathComponent("backup.json")
      try store.exportBackup(settings, to: backup)
      XCTAssertEqual(try store.readBackup(from: backup), settings)
      let damaged = Data("invalid configuration".utf8)
      try damaged.write(to: store.url)
      XCTAssertThrowsError(try store.readBackup(from: store.url))
      XCTAssertEqual(try Data(contentsOf: store.url), damaged)
      let preserved = try XCTUnwrap(store.restore(try store.readBackup(from: backup)))
      XCTAssertEqual(try Data(contentsOf: preserved), damaged)
      XCTAssertEqual(try store.load(), settings)
      XCTAssertThrowsError(try store.exportBackup(settings, to: store.url))
      XCTAssertEqual(try store.load(), settings)
    }
  }
}
