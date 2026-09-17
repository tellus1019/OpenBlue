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
      XCTAssertEqual(settings.dspValues, AudioSettings().dspValues)
      try settings.deleteSelectedPreset()
      XCTAssertEqual(settings.selectedPresetID, first.id)
      try settings.selectPreset(copyID)
      try settings.deleteSelectedPreset()
      XCTAssertThrowsError(try settings.deleteSelectedPreset())
      try store.save(settings)
      XCTAssertEqual(try store.load(), settings)
    }
  }

  func testLegacyDocumentsMigrateToOnePresetWithoutLoss() throws {
    try withStore { store in
      for version in [1, 2] {
        var object: [String: Any] = [
          "schemaVersion": version, "gainDB": -8.5, "bypass": true, "deviceUID": "legacy-yeti",
        ]
        var processing = ProcessingParameter.defaults
        for p in ProcessingParameter.stored { processing[p.key] = p.maximum }
        if version == 2 { object["processing"] = processing }
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try original.write(to: store.url)
        let migrated = try store.load()
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.presets.count, 1)
        XCTAssertEqual(migrated.selectedPreset.name, "Current Settings")
        XCTAssertEqual(migrated.gainDB, -8.5)
        XCTAssertTrue(migrated.bypass)
        XCTAssertEqual(migrated.deviceUID, "legacy-yeti")
        XCTAssertEqual(migrated.processing, version == 1 ? ProcessingParameter.defaults : processing)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        try store.save(migrated)
        XCTAssertEqual(try Data(contentsOf: store.migrationBackupURL(version: version)), original)
        XCTAssertEqual(try store.load(), migrated)
      }
    }
  }

  func testInvalidPresetDocumentsArePreserved() throws {
    try withStore { store in
      let valid = try JSONEncoder().encode(AudioSettings())
      for corruption in 0..<6 {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var presets = try XCTUnwrap(object["presets"] as? [[String: Any]])
        switch corruption {
        case 0: object["schemaVersion"] = 99
        case 1: object["selectedPresetID"] = UUID().uuidString
        case 2: presets = []
        case 3: presets.append(presets[0])
        case 4: presets[0]["name"] = " "
        default: presets[0]["processing"] = ["invalid": 1]
        }
        object["presets"] = presets
        let original = try JSONSerialization.data(withJSONObject: object)
        try original.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(AudioSettings()))
        XCTAssertEqual(try Data(contentsOf: store.url), original)
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
