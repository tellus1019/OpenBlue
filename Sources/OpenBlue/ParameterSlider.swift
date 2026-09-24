import SwiftUI

// Keep parameter precision independent of the number of visual tick marks.
struct ParameterSlider: View {
  @Binding var value: Float
  let bounds: ClosedRange<Float>
  let step: Float

  private func setValue(_ proposed: Float) {
    let steps = ((proposed - bounds.lowerBound) / step).rounded()
    let next = min(bounds.upperBound, max(bounds.lowerBound, bounds.lowerBound + steps * step))
    if value != next { value = next }
  }

  var body: some View {
    Slider(value: Binding(get: { value }, set: setValue), in: bounds)
      .onKeyPress(.leftArrow) { setValue(value - step); return .handled }
      .onKeyPress(.rightArrow) { setValue(value + step); return .handled }
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: setValue(value + step)
        case .decrement: setValue(value - step)
        @unknown default: break
        }
      }
  }
}
