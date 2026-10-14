import AppKit
import AudioCore
import Combine
import QuartzCore
import SwiftUI

@MainActor final class MeterValue {
  private(set) var value: Float = 0
  private var bars: [WeakBar] = []

  private struct WeakBar {
    weak var view: MeterBarView?
  }

  func update(_ value: Float) {
    self.value = value
    for bar in bars { bar.view?.setLevel(value) }
  }

  func clear() {
    value = 0
    for bar in bars { bar.view?.setLevel(0, animated: false) }
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
  let inputLeft = MeterValue()
  let inputRight = MeterValue()
  let outputLeft = MeterValue()
  let outputRight = MeterValue()
  let compressor = MeterValue()
  let limiter = MeterValue()
  let deEsser = MeterValue()
  let dePopper = MeterValue()
  let inputReadout = MeterText("−∞ dBFS")
  let outputReadout = MeterText("−∞ dBFS")
  let compressorReadout = MeterText("0.0 dB")
  let limiterReadout = MeterText("0.0 dB")
  let deEsserReadout = MeterText("0.0 dB")
  let dePopperReadout = MeterText("0.0 dB")

  func updateLevels(_ values: OBMeterValues) {
    inputLeft.update(values.input_left)
    inputRight.update(values.input_right)
    outputLeft.update(values.output_left)
    outputRight.update(values.output_right)
    compressor.update(values.compressor_reduction)
    limiter.update(values.limiter_reduction)
    deEsser.update(values.de_esser_reduction)
    dePopper.update(values.de_popper_reduction)
  }

  func updateReadouts(_ values: OBMeterValues) {
    inputReadout.update(Self.peakText(values.input_peak))
    outputReadout.update(Self.peakText(values.output_peak))
    compressorReadout.update(String(format: "%.1f dB", values.compressor_reduction))
    limiterReadout.update(String(format: "%.1f dB", values.limiter_reduction))
    deEsserReadout.update(String(format: "%.1f dB", values.de_esser_reduction))
    dePopperReadout.update(String(format: "%.1f dB", values.de_popper_reduction))
  }

  func clearLevels() {
    let zero = OBMeterValues()
    updateLevels(zero)
    updateReadouts(zero)
    for meter in [inputLeft, inputRight, outputLeft, outputRight] { meter.clear() }
  }

  private static func peakText(_ peak: Float) -> String {
    peak > 0 ? String(format: "%.1f dBFS", 20 * log10(peak)) : "−∞ dBFS"
  }
}

struct MeterReadout: View {
  @ObservedObject var value: MeterText
  var body: some View { Text(value.text).monospacedDigit() }
}

struct NativeLevelReadout: NSViewRepresentable {
  let value: MeterText
  let fontSize: CGFloat

  func makeNSView(context: Context) -> LevelReadoutView { LevelReadoutView() }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: LevelReadoutView, context: Context) -> CGSize? {
    CGSize(width: LevelReadoutView.width(fontSize: fontSize), height: ceil(fontSize * 1.3))
  }

  func updateNSView(_ view: LevelReadoutView, context: Context) {
    view.configure(value: value, fontSize: fontSize,
      foreground: Color.primary.resolve(in: context.environment).cgColor,
      unitColor: Color.primary.opacity(0.3).resolve(in: context.environment).cgColor)
  }
}

final class LevelReadoutView: NSView {
  private weak var source: MeterText?
  private var subscription: AnyCancellable?
  private let number = NSTextField(labelWithString: "−∞")
  private let unit = NSTextField(labelWithString: "dBFS")
  private var numberHeight: CGFloat = 0
  private var unitSize: NSSize = .zero
  private var configuredFontSize: CGFloat = 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    for label in [number, unit] {
      label.setAccessibilityElement(false)
      addSubview(label)
    }
    number.alignment = .right
    unit.font = .systemFont(ofSize: 10.5)
    // Live text must not invalidate the enclosing SwiftUI layout through Auto Layout.
    // These labels have fixed frames; only a font or container size change lays them out.
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
  }

  required init?(coder: NSCoder) { nil }

  static func width(fontSize: CGFloat) -> CGFloat {
    let number = NSTextField(labelWithString: "−100.0")
    number.font = .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
    let unit = NSTextField(labelWithString: "dBFS")
    unit.font = .systemFont(ofSize: 10.5)
    return ceil(number.fittingSize.width + 4 + unit.fittingSize.width)
  }

  override func layout() {
    super.layout()
    let numberY = (bounds.height - numberHeight) / 2
    number.frame = NSRect(x: 0, y: numberY,
      width: max(0, bounds.width - unitSize.width - 4), height: numberHeight)
    let baseline = number.frame.maxY - number.firstBaselineOffsetFromTop
    unit.frame = NSRect(x: bounds.width - unitSize.width,
      y: baseline + unit.firstBaselineOffsetFromTop - unitSize.height,
      width: unitSize.width, height: unitSize.height)
  }

  func configure(value: MeterText, fontSize: CGFloat, foreground: CGColor, unitColor: CGColor) {
    if configuredFontSize != fontSize {
      configuredFontSize = fontSize
      number.font = .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
      numberHeight = number.fittingSize.height
      unitSize = unit.fittingSize
      needsLayout = true
    }
    number.textColor = NSColor(cgColor: foreground) ?? .labelColor
    unit.textColor = NSColor(cgColor: unitColor) ?? .tertiaryLabelColor
    if source !== value {
      source = value
      // Keep live text updates inside this fixed-size AppKit view.
      // AppKit owns text layout, font fallback, and appearance changes.
      subscription = value.$text.sink { [weak self] text in
        self?.number.stringValue = text.replacingOccurrences(of: " dBFS", with: "")
          .replacingOccurrences(of: "-", with: "−")
        self?.setAccessibilityLabel(text)
      }
    }
  }
}

struct PeakMeterBar: View {
  let level: MeterValue
  var height: CGFloat = 6

  var body: some View {
    NativeMeterBar(level: level, kind: .peak)
      .frame(height: height)
      .accessibilityHidden(true)
  }
}

struct ReductionMeterBar: View {
  let level: MeterValue
  var band = false

  var body: some View {
    NativeMeterBar(level: level, kind: band ? .bandReduction : .reduction)
      .frame(height: 6)
      .frame(maxWidth: .infinity)
      .accessibilityHidden(true)
  }
}

fileprivate enum MeterBarKind {
  case peak, reduction, bandReduction
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
  private let gradient = CAGradientLayer()
  private let peak = CALayer()
  private var held: CGFloat = 0
  private var holdUntil: CFTimeInterval = 0
  private var lastUpdate: CFTimeInterval = 0
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
    if kind == .peak {
      gradient.startPoint = CGPoint(x: 0, y: 0.5)
      gradient.endPoint = CGPoint(x: 1, y: 0.5)
      gradient.locations = [0, 0.55, 0.78, 0.90, 1]
      fill.masksToBounds = true
      fill.addSublayer(gradient)
      track.addSublayer(peak)
    }
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
    fill.backgroundColor = kind == .peak ? nil : (self.clipped ? clipped : foreground)
    gradient.colors = [NSColor(red: 0.12, green: 0.72, blue: 1, alpha: 1).cgColor,
      NSColor.controlAccentColor.cgColor, NSColor(red: 0.49, green: 0.36, blue: 1, alpha: 1).cgColor,
      NSColor(red: 1, green: 0.69, blue: 0.13, alpha: 1).cgColor,
      NSColor(red: 1, green: 0.30, blue: 0.30, alpha: 1).cgColor]
    peak.backgroundColor = foreground
    CATransaction.commit()
  }

  func setLevel(_ value: Float, animated: Bool = true) {
    let nextFraction: CGFloat
    switch kind {
    case .peak:
      nextFraction = CGFloat(max(0, min(1, (Double(20 * log10(max(value, 0.000001))) + 60) / 60)))
    case .reduction:
      nextFraction = CGFloat(max(0, min(1, Double(value) / 30)))
    case .bandReduction:
      nextFraction = CGFloat(max(0, min(1, Double(value) / 60)))
    }
    let nextClipped = kind == .peak && value >= 0.99
    let now = CACurrentMediaTime()
    let elapsed = lastUpdate == 0 ? 0 : now - lastUpdate
    lastUpdate = now
    if nextFraction >= held { held = nextFraction; holdUntil = now + 0.5 }
    else if now > holdUntil { held = max(nextFraction, held - CGFloat(elapsed) * 200 / 60) }
    if !animated && value == 0 { held = 0; holdUntil = 0 }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    peak.frame = CGRect(x: max(0, bounds.width * held - 2), y: 0, width: held > 0 ? 2 : 0, height: bounds.height)
    CATransaction.commit()
    guard fraction != nextFraction || clipped != nextClipped else { return }
    fraction = nextFraction
    let width = bounds.width * fraction
    let previousWidth = fill.presentation()?.bounds.width ?? fill.bounds.width
    let widthChanged = fill.bounds.width != width

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if clipped != nextClipped {
      clipped = nextClipped
      if kind != .peak { fill.backgroundColor = clipped ? clippedColor : foregroundColor }
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
    gradient.frame = bounds
    peak.frame = CGRect(x: max(0, bounds.width * held - 2), y: 0, width: held > 0 ? 2 : 0, height: bounds.height)
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
    gradient.contentsScale = scale
    peak.contentsScale = scale
    CATransaction.commit()
  }
}

// Main and Quick Access windows share one display polling schedule.
@MainActor final class InterfaceWindowReference {
  weak var window: NSWindow?
}

struct MeterWindowObserver: NSViewRepresentable {
  let model: AudioModel
  var reference: InterfaceWindowReference? = nil

  func makeNSView(context: Context) -> MeterWindowView {
    MeterWindowView(model: model, reference: reference)
  }

  func updateNSView(_ nsView: MeterWindowView, context: Context) {}

  static func dismantleNSView(_ nsView: MeterWindowView, coordinator: ()) {
    nsView.detach()
  }
}

final class MeterWindowView: NSView {
  private weak var model: AudioModel?
  private let reference: InterfaceWindowReference?

  init(model: AudioModel, reference: InterfaceWindowReference?) {
    self.model = model
    self.reference = reference
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    detach()
    reference?.window = window
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
