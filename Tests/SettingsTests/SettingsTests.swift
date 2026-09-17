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
