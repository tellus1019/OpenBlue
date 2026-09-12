import XCTest

@testable import Settings

final class SettingsTests: XCTestCase {
  func testRoundTripAndUnknownVersionPreservation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    XCTAssertEqual(try store.load(), AudioSettings())
    var s = AudioSettings()
    s.gainDB = -7.5
    s.bypass = true
    s.deviceUID = "test-yeti"
    try store.save(s)
    XCTAssertEqual(try store.load(), s)
    let newer = Data(#"{"schemaVersion":9,"gainDB":0,"bypass":false}"#.utf8)
    try newer.write(to: store.url)
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.save(s))
    XCTAssertEqual(try Data(contentsOf: store.url), newer)
  }
  func testMalformedAndInvalidGainArePreserved() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    for text in ["invalid", #"{"schemaVersion":1,"gainDB":100,"bypass":false}"#] {
      let original = Data(text.utf8)
      try original.write(to: store.url)
      XCTAssertThrowsError(try store.save(AudioSettings()))
      XCTAssertEqual(try Data(contentsOf: store.url), original)
    }
  }
}

extension SettingsTests {
  func testLegacyMigrationPreservesOriginalAndEverySetting() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    let old = Data(#"{"schemaVersion":1,"gainDB":-8.5,"bypass":true,"deviceUID":"legacy-yeti"}"#.utf8)
    try old.write(to: store.url)
    let migrated = try store.load()
    XCTAssertEqual(migrated.schemaVersion, 2)
    XCTAssertEqual(migrated.gainDB, -8.5)
    XCTAssertTrue(migrated.bypass)
    XCTAssertEqual(migrated.deviceUID, "legacy-yeti")
    XCTAssertEqual(migrated.processing, ProcessingParameter.defaults)
    XCTAssertEqual(try Data(contentsOf: store.url), old)
    try store.save(migrated)
    XCTAssertEqual(try store.load(), migrated)
    XCTAssertEqual(try Data(contentsOf: store.migrationBackupURL), old)
    var adjusted = migrated
    for parameter in ProcessingParameter.stored {
      adjusted.processing[parameter.key] = parameter.maximum
    }
    try store.save(adjusted)
    XCTAssertEqual(try store.load(), adjusted)
    XCTAssertEqual(try Data(contentsOf: store.migrationBackupURL), old)
  }

  func testInvalidProcessingAndMissingFieldsNeverOverwrite() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
    for corruption in 0..<4 {
      var settings = AudioSettings()
      switch corruption {
      case 0: settings.processing.removeValue(forKey: "noiseFloor")
      case 1: settings.processing["noiseFloor"] = 2
      case 2: settings.processing["limiterEnabled"] = 0.5
      default: settings.processing["futureParameter"] = 1
      }
      let original = try JSONEncoder().encode(settings)
      try original.write(to: store.url)
      XCTAssertThrowsError(try store.load())
      XCTAssertThrowsError(try store.save(AudioSettings()))
      XCTAssertEqual(try Data(contentsOf: store.url), original)
    }
  }
}
