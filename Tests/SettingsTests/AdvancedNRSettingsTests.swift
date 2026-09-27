import XCTest
@testable import Settings

final class AdvancedNRSettingsTests: XCTestCase {
  func testLegacySchemaFourRetainsValuesAndSelectsStandard() throws {
    var settings = AudioSettings()
    settings.gainDB = -3.5
    let original = settings
    let data = try JSONEncoder().encode(settings)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
    let factory = settings.selectedPreset
    settings.noiseReductionMode = .advanced
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
    XCTAssertEqual(settings.noiseReductionMode, .standard)
    XCTAssertEqual(settings.selectedPreset, factory)
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
