import AudioCore

public struct ProcessingParameter: Identifiable, Sendable {
  public let id: Int
  public let key, label, unit: String
  public let group: Int
  public let minimum, maximum, initial, step: Float
  public let kind: OBParameterKind
  public var isToggle: Bool { kind == OB_PARAMETER_BOOLEAN }

  public static let all: [ProcessingParameter] = (0..<Int(ob_parameter_count())).map { index in
    let p = ob_parameter_info(UInt32(index))!.pointee
    return ProcessingParameter(
      id: index, key: String(cString: p.key), label: String(cString: p.label),
      unit: String(cString: p.unit), group: Int(p.group),
      minimum: p.minimum, maximum: p.maximum, initial: p.initial, step: p.step, kind: p.kind)
  }
  public static let stored = Array(all.dropFirst(2))
  public static let defaults = Dictionary(uniqueKeysWithValues: stored.map { ($0.key, $0.initial) })
}
