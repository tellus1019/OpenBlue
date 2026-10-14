import Foundation

enum LegacySettings {
  static let ranges: [String: ClosedRange<Float>] = [
    "outputGain": (-24)...(12),
    "hpfEnabled": (0)...(1),
    "hpfFrequency": (20)...(400),
    "noiseReductionEnabled": (0)...(1),
    "noiseFloor": (-80)...(-20),
    "noiseReductionRange": (0)...(40),
    "noiseReductionRelease": (20)...(1000),
    "gateEnabled": (0)...(1),
    "gateThreshold": (-80)...(-6),
    "gateAttack": (0.1)...(200),
    "gateHold": (0)...(200),
    "gateRelease": (10)...(1000),
    "gateRange": (0)...(80),
    "eqEnabled": (0)...(1),
    "eqLowFrequency": (20)...(500),
    "eqLowGain": (-12)...(12),
    "eqLowQ": (0.5)...(10),
    "eqMidFrequency": (400)...(5000),
    "eqMidGain": (-12)...(12),
    "eqMidQ": (0.5)...(10),
    "eqHighFrequency": (1000)...(12000),
    "eqHighGain": (-12)...(12),
    "eqHighQ": (0.5)...(10),
    "deEsserEnabled": (0)...(1),
    "deEsserFrequency": (1000)...(10000),
    "deEsserThreshold": (-50)...(0),
    "deEsserRange": (0)...(30),
    "deEsserAttack": (0.1)...(200),
    "deEsserRelease": (20)...(1000),
    "dePopperEnabled": (0)...(1),
    "dePopperFrequency": (60)...(1000),
    "dePopperThreshold": (-50)...(0),
    "dePopperRange": (0)...(30),
    "dePopperAttack": (0.1)...(200),
    "dePopperRelease": (20)...(1000),
    "compressorEnabled": (0)...(1),
    "compressorThreshold": (-40)...(0),
    "compressorRatio": (1)...(20),
    "compressorAttack": (0.1)...(200),
    "compressorRelease": (50)...(1000),
    "compressorMakeup": (-12)...(12),
    "limiterEnabled": (0)...(1),
    "limiterCeiling": (-12)...(0),
    "limiterRelease": (10)...(500),
  ]
  struct Value: Decodable {
    var id: UUID
    var name: String
    var gainDB: Float
    var bypass: Bool
    var processing: [String: Float]
  }
  static func validate(gain: Float, processing: [String: Float]?) throws {
    guard gain.isFinite, (-24...12).contains(gain) else { throw SettingsError.invalidGain }
    if let processing {
      guard Set(processing.keys) == Set(ranges.keys) else { throw SettingsError.invalidProcessing }
      for (key, value) in processing {
        let range = ranges[key]!
        guard value.isFinite, range.contains(value),
          !(range == 0...1) || value == 0 || value == 1
        else { throw SettingsError.invalidProcessing }
      }
    }
  }
}
