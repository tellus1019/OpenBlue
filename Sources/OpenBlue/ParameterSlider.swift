import AppKit
import SwiftUI

struct ParameterSlider: NSViewRepresentable {
  @Binding var value: Float
  let bounds: ClosedRange<Float>
  let step: Float
  var logarithmic = false
  var centered = false

  static func rounded(_ value: Float, bounds: ClosedRange<Float>, step: Float) -> Float {
    min(bounds.upperBound, max(bounds.lowerBound,
      bounds.lowerBound + ((value - bounds.lowerBound) / step).rounded() * step))
  }

  func makeNSView(context: Context) -> NSSlider {
    let slider = PrecisionSlider()
    slider.cell = ParameterSliderCell()
    slider.minValue = 0
    slider.maxValue = 1
    slider.isContinuous = true
    slider.target = context.coordinator
    slider.action = #selector(Coordinator.changed(_:))
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return slider
  }

  func updateNSView(_ slider: NSSlider, context: Context) {
    context.coordinator.parent = self
    let position: (Float) -> Double = { v in
      logarithmic ? log(Double(v / bounds.lowerBound)) / log(Double(bounds.upperBound / bounds.lowerBound))
        : Double((v - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound))
    }
    slider.doubleValue = position(min(bounds.upperBound, max(bounds.lowerBound, value)))
    slider.isEnabled = context.environment.isEnabled
    (slider.cell as? ParameterSliderCell)?.origin = centered ? position(0) : 0
    (slider as? PrecisionSlider)?.adjust = { delta in
      value = Self.rounded(value + Float(delta) * step, bounds: bounds, step: step)
    }
    slider.setAccessibilityValue(String(value))
    slider.needsDisplay = true
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  @MainActor final class Coordinator: NSObject {
    var parent: ParameterSlider
    init(_ parent: ParameterSlider) { self.parent = parent }
    @objc func changed(_ sender: NSSlider) {
      let p = parent, x = Float(sender.doubleValue)
      let next = p.logarithmic ? p.bounds.lowerBound * pow(p.bounds.upperBound / p.bounds.lowerBound, x)
        : p.bounds.lowerBound + x * (p.bounds.upperBound - p.bounds.lowerBound)
      p.value = ParameterSlider.rounded(next, bounds: p.bounds, step: p.step)
    }
  }
}

private final class PrecisionSlider: NSSlider {
  var adjust: ((Int) -> Void)?
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123, 125: adjust?(-1)
    case 124, 126: adjust?(1)
    default: super.keyDown(with: event)
    }
  }
  override func accessibilityPerformIncrement() -> Bool { adjust?(1); return true }
  override func accessibilityPerformDecrement() -> Bool { adjust?(-1); return true }
}

private final class ParameterSliderCell: NSSliderCell {
  var origin: Double = 0
  override var knobThickness: CGFloat { 16 }
  override func drawBar(inside rect: NSRect, flipped: Bool) {
    let bar = NSRect(x: rect.minX + 8, y: rect.midY - 2, width: max(0, rect.width - 16), height: 4)
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
    let current = CGFloat((doubleValue - minValue) / (maxValue - minValue))
    let start = CGFloat(origin)
    let fill = NSRect(x: bar.minX + min(start, current) * bar.width, y: bar.minY,
                      width: abs(current - start) * bar.width, height: 4)
    NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
    NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
  }
  override func drawKnob(_ rect: NSRect) {
    let knob = NSRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 2
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: knob).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.18).setStroke()
    let outline = NSBezierPath(ovalIn: knob.insetBy(dx: 0.25, dy: 0.25))
    outline.lineWidth = 0.5
    outline.stroke()
  }
}

struct ParameterValueFormat {
  let bounds: ClosedRange<Float>
  let step: Float
  let unit: String
  func parts(_ value: Float) -> (number: String, unit: String) {
    if unit == "Hz", value >= 1000 {
      var text = String(format: value >= 10000 ? "%.1f" : "%.2f", value / 1000)
      while text.last == "0" { text.removeLast() }
      if text.last == "." { text.removeLast() }
      return (text, "kHz")
    }
    let digits = step == 0.25 ? 2 : step < 1 ? 1 : 0
    var text = String(format: "%.*f", digits, abs(value))
    if value < 0 { text = "−" + text }
    else if unit == "dB", bounds.lowerBound < 0, bounds.upperBound > 0, value > 0 { text = "+" + text }
    return (text, unit == ":1" || unit == "ratio" ? ": 1" : unit)
  }
  func text(_ value: Float) -> String {
    let p = parts(value)
    return p.number + (p.unit.isEmpty ? "" : " " + p.unit)
  }
}

struct ParameterValueField: View {
  @Binding var value: Float
  let format: ParameterValueFormat
  let label: String
  var contextID: UUID? = nil
  @State private var draft = ""
  @State private var inputScale: Float = 1
  @State private var skipBlurCommit = false
  @State private var draftChanged = false
  @FocusState private var editing: Bool

  private func commit() {
    skipBlurCommit = true
    let normalized = draft.replacingOccurrences(of: "−", with: "-")
    if draftChanged, let number = Float(normalized), number.isFinite {
      value = ParameterSlider.rounded(number * inputScale, bounds: format.bounds, step: format.step)
    }
    editing = false
  }
  private func adjust(_ direction: Float) {
    if editing { commit() }
    value = ParameterSlider.rounded(value + direction * format.step, bounds: format.bounds, step: format.step)
  }
  var body: some View {
    HStack(spacing: 0) {
      Button { adjust(-1) } label: { Text("−").frame(width: 20, height: 24) }
        .accessibilityLabel("Decrease " + label)
      TextField(label, text: Binding(get: { editing ? draft : format.parts(value).number }, set: { draft = $0; draftChanged = true }))
        .textFieldStyle(.plain).multilineTextAlignment(.trailing)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .frame(width: 49).focused($editing).onSubmit(commit)
        .onExitCommand { skipBlurCommit = true; editing = false }
        .onChange(of: editing) { _, active in
          if active {
            skipBlurCommit = false
            draftChanged = false
            draft = format.parts(value).number
            inputScale = format.parts(value).unit == "kHz" ? 1000 : 1
          } else if !skipBlurCommit, draftChanged, let number = Float(draft.replacingOccurrences(of: "−", with: "-")), number.isFinite {
            value = ParameterSlider.rounded(number * inputScale, bounds: format.bounds, step: format.step)
          }
        }
      Text(editing && inputScale == 1000 ? "kHz" : format.parts(value).unit)
        .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.leading, 4).frame(minWidth: 26)
      Button { adjust(1) } label: { Text("+").frame(width: 20, height: 24) }
        .accessibilityLabel("Increase " + label)
    }
    .onChange(of: contextID) { _, _ in
      skipBlurCommit = true
      editing = false
      draft = format.parts(value).number
    }
    .buttonStyle(.plain).foregroundStyle(.primary)
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(editing ? Color.accentColor : UIStyle.line, lineWidth: 1))
  }
}
