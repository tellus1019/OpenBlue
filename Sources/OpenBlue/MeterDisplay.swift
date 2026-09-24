import AppKit
import AudioCore
import QuartzCore
import SwiftUI

@MainActor final class MeterValue {
  private(set) var value: Float = 0
  private var bars: [WeakBar] = []

  private struct WeakBar {
    weak var view: MeterBarView?
  }

  func update(_ value: Float) {
    guard self.value != value else { return }
    self.value = value
    for bar in bars { bar.view?.setLevel(value) }
  }

  fileprivate func attach(_ bar: MeterBarView) {
    bars.removeAll { $0.view == nil || $0.view === bar }
    bars.append(WeakBar(view: bar))
    bar.setLevel(value, animated: false)
  }

  fileprivate func detach(_ bar: MeterBarView) {
    bars.removeAll { $0.view == nil || $0.view === bar }
  }
}

@MainActor final class MeterText: ObservableObject {
  @Published private(set) var text: String

  init(_ text: String = "") { self.text = text }

  func update(_ text: String) {
    if self.text != text { self.text = text }
  }
}

@MainActor final class MeterDisplay {
  static let updateInterval: TimeInterval = 1.0 / 60.0
  let input = MeterValue()
  let output = MeterValue()
  let compressor = MeterValue()
  let limiter = MeterValue()
  let inputReadout = MeterText("−∞ dBFS")
  let outputReadout = MeterText("−∞ dBFS")
  let compressorReadout = MeterText("0.0 dB")
  let limiterReadout = MeterText("0.0 dB")
  let diagnostics = MeterText()

  func updateLevels(_ values: OBMeterValues) {
    input.update(values.input_raw_peak)
    output.update(values.output_raw_peak)
    compressor.update(values.compressor_reduction)
    limiter.update(values.limiter_reduction)
  }

  func updateReadouts(_ values: OBMeterValues) {
    inputReadout.update(Self.peakText(values.input_peak))
    outputReadout.update(Self.peakText(values.output_peak))
    compressorReadout.update(String(format: "%.1f dB", values.compressor_reduction))
    limiterReadout.update(String(format: "%.1f dB", values.limiter_reduction))
  }

  func clearLevels() {
    let zero = OBMeterValues()
    updateLevels(zero)
    updateReadouts(zero)
  }

  private static func peakText(_ peak: Float) -> String {
    peak > 0 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "−∞ dBFS"
  }
}

private struct MeterReadout: View {
  @ObservedObject var value: MeterText
  var body: some View { Text(value.text).monospacedDigit() }
}

private struct MeterDiagnostics: View {
  @ObservedObject var value: MeterText
  var body: some View { Text(value.text).font(.caption).foregroundStyle(.secondary) }
}

struct PeakMeterBar: View {
  let level: MeterValue

  var body: some View {
    NativeMeterBar(level: level, kind: .peak)
      .frame(height: 6)
      .accessibilityHidden(true)
  }
}

struct ReductionMeterBar: View {
  let level: MeterValue

  var body: some View {
    NativeMeterBar(level: level, kind: .reduction)
      .frame(height: 6)
      .frame(maxWidth: .infinity)
      .accessibilityHidden(true)
  }
}

fileprivate enum MeterBarKind {
  case peak, reduction
}

private struct NativeMeterBar: NSViewRepresentable {
  let level: MeterValue
  let kind: MeterBarKind

  func makeNSView(context: Context) -> MeterBarView {
    let view = MeterBarView(kind: kind)
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: MeterBarView, context: Context) {
    let foreground: Color = kind == .peak ? .primary : .orange
    nsView.setColors(
      background: Color.secondary.opacity(0.2).resolve(in: context.environment).cgColor,
      foreground: foreground.resolve(in: context.environment).cgColor,
      clipped: Color.red.resolve(in: context.environment).cgColor)
    nsView.bind(to: level)
  }

  static func dismantleNSView(_ nsView: MeterBarView, coordinator: ()) {
    nsView.unbind()
  }
}

fileprivate final class MeterBarView: NSView {
  private let kind: MeterBarKind
  private let track = CALayer()
  private let fill = CALayer()
  private weak var source: MeterValue?
  private var fraction: CGFloat = 0
  private var clipped = false
  private var foregroundColor: CGColor?
  private var clippedColor: CGColor?
  private var laidOutSize: CGSize = .zero
  private static let widthAnimationKey = "meterWidth"

  init(kind: MeterBarKind) {
    self.kind = kind
    super.init(frame: .zero)
    // Set the layer first so this view hosts a layer tree owned by the meter.
    layer = track
    wantsLayer = true
    track.masksToBounds = true
    fill.anchorPoint = .zero
    track.addSublayer(fill)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { return nil }

  func bind(to value: MeterValue) {
    guard source !== value else { return }
    unbind()
    source = value
    value.attach(self)
  }

  func unbind() {
    source?.detach(self)
    source = nil
  }

  func setColors(background: CGColor, foreground: CGColor, clipped: CGColor) {
    guard track.backgroundColor != background || foregroundColor != foreground
      || clippedColor != clipped else { return }
    foregroundColor = foreground
    clippedColor = clipped
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.backgroundColor = background
    fill.backgroundColor = self.clipped ? clipped : foreground
    CATransaction.commit()
  }

  func setLevel(_ value: Float, animated: Bool = true) {
    let nextFraction: CGFloat
    switch kind {
    case .peak:
      nextFraction = CGFloat(max(0, min(1, (Double(20 * log10(max(value, 0.000001))) + 60) / 60)))
    case .reduction:
      nextFraction = CGFloat(max(0, min(1, Double(value) / 30)))
    }
    let nextClipped = kind == .peak && value >= 0.99
    guard fraction != nextFraction || clipped != nextClipped else { return }
    fraction = nextFraction
    let width = bounds.width * fraction
    let previousWidth = fill.presentation()?.bounds.width ?? fill.bounds.width
    let widthChanged = fill.bounds.width != width

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if clipped != nextClipped {
      clipped = nextClipped
      fill.backgroundColor = clipped ? clippedColor : foregroundColor
    }
    if widthChanged {
      fill.bounds.size.width = width
      if animated && window != nil && bounds.width > 0 && previousWidth != width {
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = previousWidth
        animation.toValue = width
        // Smooth both directions over three updates at 60 Hz.
        animation.duration = 3 * MeterDisplay.updateInterval
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.add(animation, forKey: Self.widthAnimationKey)
      } else {
        fill.removeAnimation(forKey: Self.widthAnimationKey)
      }
    }
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    guard laidOutSize != bounds.size else { return }
    laidOutSize = bounds.size
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.frame = bounds
    track.cornerRadius = bounds.height / 2
    fill.removeAnimation(forKey: Self.widthAnimationKey)
    fill.position = .zero
    fill.bounds = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateScale()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScale()
  }

  private func updateScale() {
    guard let scale = window?.backingScaleFactor else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.contentsScale = scale
    fill.contentsScale = scale
    CATransaction.commit()
  }
}

struct MeterPanel: View {
  let display: MeterDisplay

  private func peak(_ title: String, readout: MeterText, level: MeterValue) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
        Spacer()
        MeterReadout(value: readout)
      }
      PeakMeterBar(level: level)
    }
  }

  private func reduction(_ title: String, readout: MeterText, level: MeterValue) -> some View {
    VStack(alignment: .leading) {
      HStack {
        Text(title + " reduction")
        Spacer()
        MeterReadout(value: readout)
      }.font(.caption)
      ReductionMeterBar(level: level)
    }
  }

  var body: some View {
    VStack(spacing: 22) {
      peak("Input", readout: display.inputReadout, level: display.input)
      peak("Output", readout: display.outputReadout, level: display.output)
      HStack {
        reduction("Compressor", readout: display.compressorReadout, level: display.compressor)
        reduction("Limiter", readout: display.limiterReadout, level: display.limiter)
      }
      MeterDiagnostics(value: display.diagnostics)
    }
  }
}

// Only a content window contributes visibility; a menu-bar window does not.
struct MeterWindowObserver: NSViewRepresentable {
  let model: AudioModel

  func makeNSView(context: Context) -> MeterWindowView {
    MeterWindowView(model: model)
  }

  func updateNSView(_ nsView: MeterWindowView, context: Context) {}

  static func dismantleNSView(_ nsView: MeterWindowView, coordinator: ()) {
    nsView.detach()
  }
}

final class MeterWindowView: NSView {
  private weak var model: AudioModel?

  init(model: AudioModel) {
    self.model = model
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    detach()
    guard let window else { return }
    let center = NotificationCenter.default
    for name in [NSWindow.didChangeOcclusionStateNotification,
                 NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
      center.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
    }
    center.addObserver(
      self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification,
      object: window)
    for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
      center.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: NSApp)
    }
    // Window attachment can occur during a SwiftUI update.
    DispatchQueue.main.async { [weak self] in self?.updateVisibility() }
  }

  func detach() {
    NotificationCenter.default.removeObserver(self)
    model?.setMeterWindowVisible(ObjectIdentifier(self), visible: false)
  }

  @objc private func visibilityChanged(_ notification: Notification) { updateVisibility() }
  @objc private func windowClosing(_ notification: Notification) {
    model?.setMeterWindowVisible(ObjectIdentifier(self), visible: false)
  }

  private func updateVisibility() {
    let visible = window.map {
      $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !NSApp.isHidden
    } ?? false
    model?.setMeterWindowVisible(ObjectIdentifier(self), visible: visible)
  }
}
