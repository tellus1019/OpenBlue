public struct RecoveryBackoff: Equatable, Sendable {
  public let initialDelay: Double
  public let maximumDelay: Double
  public private(set) var attempt = 0

  public init(initialDelay: Double = 0.5, maximumDelay: Double = 8) {
    precondition(initialDelay > 0 && maximumDelay >= initialDelay)
    self.initialDelay = initialDelay
    self.maximumDelay = maximumDelay
  }

  public mutating func nextDelay() -> Double {
    let exponent = min(attempt, 30)
    let delay = min(maximumDelay, initialDelay * Double(1 << exponent))
    attempt += 1
    return delay
  }

  public mutating func reset() {
    attempt = 0
  }
}
