import AppKit
import Settings
import SwiftUI

enum UIStyle {
  static let window = Color(nsColor: .windowBackgroundColor)
  // Under-page gray is much darker than a sidebar on some macOS versions.
  static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(red: 0.114, green: 0.118, blue: 0.133, alpha: 1)
      : NSColor(red: 0.937, green: 0.937, blue: 0.925, alpha: 1)
  })
  static let panel = Color(nsColor: .controlBackgroundColor)
  static let line = Color(nsColor: .separatorColor).opacity(0.55)
}

extension AudioModel {
  var enabledBinding: Binding<Bool> { Binding(get: { self.enabled }, set: { self.setEnabled($0) }) }
  var bypassBinding: Binding<Bool> {
    Binding(get: { self.settings.bypass }, set: { v in _ = self.changePreset { $0.bypass = v } })
  }
  var muteBinding: Binding<Bool> { processingToggle("masterMute") }
  var outputBinding: Binding<Float> {
    Binding(get: { self.settings.processing["masterOutput"] ?? 0 },
      set: { v in _ = self.changePreset { $0.processing["masterOutput"] = v } })
  }
  var inputBinding: Binding<Float> {
    Binding(get: { self.settings.gainDB }, set: { v in _ = self.changePreset { $0.gainDB = v } })
  }
  func processingValue(_ p: ProcessingParameter) -> Binding<Float> {
    Binding(get: { self.settings.processing[p.key] ?? p.initial },
      set: { v in _ = self.changePreset { $0.processing[p.key] = v } })
  }
  func processingToggle(_ key: String) -> Binding<Bool> {
    Binding(get: { self.settings.processing[key] == 1 },
      set: { v in _ = self.changePreset { $0.processing[key] = v ? 1 : 0 } })
  }
  var processorCount: Int {
    ProcessorDescription.all.filter { settings.processing[$0.toggle.key] == 1 }.count
  }
  var presetGroup: String { settings.isFactorySelected ? "Factory" : "My preset" }
}

struct PresetBadge: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
      .padding(.vertical, 2).padding(.horizontal, 7)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4)).fixedSize()
  }
}

struct SurfaceButtonStyle: ButtonStyle {
  var height: CGFloat = 28
  var primary = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12, weight: .medium))
      .frame(maxWidth: .infinity).frame(height: height)
      .foregroundStyle(primary ? Color.white : Color.primary)
      .background(primary ? Color.accentColor : UIStyle.panel, in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? .clear : UIStyle.line))
      .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
  }
}

struct ToggleCard: View {
  let title: String
  @Binding var value: Bool
  var compact = false
  var body: some View {
    HStack {
      Button { value.toggle() } label: {
        Text(title).font(.system(size: 12.5, weight: .semibold))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
      Toggle(title, isOn: $value).labelsHidden().toggleStyle(.switch).controlSize(.small)
        .tint(title == "Mute" ? .red : .accentColor)
    }
    .padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: compact ? 9 : 12).fill(UIStyle.panel)
        .onTapGesture { value.toggle() }
    }
    .overlay(RoundedRectangle(cornerRadius: compact ? 9 : 12).strokeBorder(UIStyle.line))
  }
}

struct AudioStatusPresentation {
  let name: String
  let detail: String
  let color: Color
  let showsDelay: Bool
}

struct AudioStatusView: View {
  @ObservedObject var model: AudioModel
  var compact = false
  var body: some View {
    let state = model.presentation
    HStack(spacing: 8) {
      Circle().fill(state.color).frame(width: 7, height: 7)
      Text(state.name).font(.system(size: 12, weight: .medium)).fixedSize()
      if !compact || state.showsDelay {
        Text(state.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      if state.showsDelay && !compact {
        Text("·").foregroundStyle(.tertiary)
        Text(model.latencyLabel).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
      }
    }.help(model.status + "\n" + model.processingDelayDescription)
  }
}

struct MainTitlebar: View {
  @ObservedObject var model: AudioModel
  var body: some View {
    HStack(spacing: 16) {
      Spacer(minLength: 90)
      AudioStatusView(model: model)
      Rectangle().fill(UIStyle.line).frame(width: 1, height: 20)
      Toggle("Enabled", isOn: model.enabledBinding).toggleStyle(.switch).controlSize(.small)
        .font(.system(size: 12.5, weight: .medium)).disabled(model.settingsError != nil)
    }.padding(.horizontal, 18).frame(height: 52)
      .background(UIStyle.sidebar)
      .overlay(alignment: .bottom) { Rectangle().fill(UIStyle.line).frame(height: 1) }
  }
}

struct MainMeterRow: View {
  @ObservedObject var model: AudioModel
  var body: some View {
    HStack(spacing: 14) {
      GainMeterCard(title: "Input", subtitle: model.inputDescription, gainLabel: "Input gain",
        readout: model.meterDisplay.inputReadout, left: model.meterDisplay.inputLeft,
        right: model.meterDisplay.inputRight, gain: model.inputBinding, bounds: -24...12)
      GainMeterCard(title: "Output", subtitle: "OpenBlue mic", gainLabel: "Output",
        readout: model.meterDisplay.outputReadout, left: model.meterDisplay.outputLeft,
        right: model.meterDisplay.outputRight, gain: model.outputBinding, bounds: -80...0)
      VStack(spacing: 8) {
        ToggleCard(title: "Bypass", value: model.bypassBinding)
        ToggleCard(title: "Mute", value: model.muteBinding)
      }.frame(width: 150)
    }.frame(height: 100).padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
      .opacity(model.enabled ? 1 : 0.35).disabled(model.settingsError != nil)
  }
}

struct GainMeterCard: View {
  let title: String
  let subtitle: String
  let gainLabel: String
  let readout: MeterText
  let left: MeterValue
  let right: MeterValue
  @Binding var gain: Float
  let bounds: ClosedRange<Float>
  var body: some View {
    VStack(spacing: 9) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
          }
          Text(title).font(.system(size: 12, weight: .semibold)).help(subtitle)
        }
        Spacer(minLength: 0)
        LevelReadout(value: readout, size: 18)
      }
      StereoMeter(left: left, right: right)
      HStack(spacing: 10) {
        Text(gainLabel).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
        ParameterSlider(value: $gain, bounds: bounds, step: 0.5, centered: bounds.upperBound > 0)
          .frame(height: 16).accessibilityLabel(gainLabel)
        Text(ParameterValueFormat(bounds: bounds, step: 0.5, unit: "dB").text(gain))
          .font(.system(size: 11.5, design: .monospaced)).frame(width: 60, alignment: .trailing)
      }
    }.padding(.vertical, 12).padding(.horizontal, 14).frame(maxWidth: .infinity)
      .background(UIStyle.panel, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UIStyle.line))
  }
}

struct LevelReadout: View {
  let value: MeterText
  let size: CGFloat
  var body: some View {
    NativeLevelReadout(value: value, fontSize: size)
      .frame(width: LevelReadoutView.width(fontSize: size), height: ceil(size * 1.3))
      .alignmentGuide(.firstTextBaseline) { _ in NSFont.monospacedSystemFont(ofSize: size, weight: .semibold).ascender }
  }
}

struct StereoMeter: View {
  let left: MeterValue
  let right: MeterValue
  var height: CGFloat = 6
  var body: some View {
    VStack(spacing: 4) {
      PeakMeterBar(level: left, height: height).help("Left channel")
      PeakMeterBar(level: right, height: height).help("Right channel")
    }.accessibilityLabel("Stereo level")
  }
}

struct MenuBarLabel: View {
  @ObservedObject var model: AudioModel
  private static let activeIcon = NSImage(named: "MenuBarIcon") ?? NSImage(size: NSSize(width: 22, height: 22))
  private static let inactiveIcon: NSImage = {
    let image = NSImage(size: activeIcon.size, flipped: false) { rect in
      activeIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.45)
      return true
    }
    image.isTemplate = true
    return image
  }()
  var body: some View {
    Image(nsImage: model.enabled ? Self.activeIcon : Self.inactiveIcon).renderingMode(.template)
      .accessibilityLabel("OpenBlue, " + model.presentation.name)
  }
}

struct QuickAccess: View {
  @ObservedObject var model: AudioModel
  let delegate: AppDelegate
  private func open(_ action: () -> Void) { delegate.quickAccessWindow.window?.orderOut(nil); action() }
  private func menuRow(_ title: String, shortcut: String = "", action: @escaping () -> Void) -> some View {
    Button { open(action) } label: {
      HStack { Text(title); Spacer(); Text(shortcut).foregroundStyle(.tertiary) }
        .font(.system(size: 12.5)).padding(.horizontal, 6).frame(height: 26).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("OpenBlue").font(.system(size: 15, weight: .bold))
        Spacer()
        Toggle("Enabled", isOn: model.enabledBinding).toggleStyle(.switch).controlSize(.small)
          .font(.system(size: 12)).disabled(model.settingsError != nil)
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 4) {
          AudioStatusView(model: model, compact: true)
          Spacer(minLength: 0)
          LevelReadout(value: model.meterDisplay.outputReadout, size: 11.5)
        }
        StereoMeter(left: model.meterDisplay.outputLeft, right: model.meterDisplay.outputRight, height: 5)
          .opacity(!model.enabled || model.muteBinding.wrappedValue ? 0.3 : 1)
        if !model.presentation.showsDelay && model.presentation.name != "Stopped" {
          Text(model.presentation.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.padding(.vertical, 10).padding(.horizontal, 12)
        .background(UIStyle.panel, in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 6) {
        Text("Preset").font(.system(size: 11)).foregroundStyle(.secondary)
        PresetMenuButton(model: model).frame(height: 32)
      }.disabled(model.settingsError != nil)
      VStack(spacing: 6) {
        HStack {
          Text("Output").foregroundStyle(.secondary)
          Spacer()
          Text(ParameterValueFormat(bounds: -80...0, step: 0.5, unit: "dB").text(model.outputBinding.wrappedValue)).monospacedDigit()
        }.font(.system(size: 11.5))
        ParameterSlider(value: model.outputBinding, bounds: -80...0, step: 0.5)
          .frame(height: 18).accessibilityLabel("Output")
      }.disabled(model.settingsError != nil)
      HStack(spacing: 8) {
        ToggleCard(title: "Bypass", value: model.bypassBinding, compact: true)
        ToggleCard(title: "Mute", value: model.muteBinding, compact: true)
      }.frame(height: 36).disabled(model.settingsError != nil)
      Button("Show OpenBlue") { open(delegate.showMainWindow) }.buttonStyle(SurfaceButtonStyle(height: 32, primary: true))
      Divider()
      VStack(spacing: 0) {
        menuRow("Settings…", shortcut: "⌘,") { delegate.showSettingsWindow() }
        menuRow("About OpenBlue") { delegate.showAboutWindow() }
        menuRow("Quit OpenBlue", shortcut: "⌘Q") { NSApp.terminate(nil) }
      }
    }.padding(14).frame(width: 320).background(UIStyle.window, in: RoundedRectangle(cornerRadius: 14))
      .background(MeterWindowObserver(model: model, reference: delegate.quickAccessWindow))
  }
}

private struct PresetMenuLabel: View {
  @ObservedObject var model: AudioModel
  var body: some View {
    HStack(spacing: 6) {
      Text(model.settings.selectedPreset.name).font(.system(size: 12.5)).lineLimit(1)
      Spacer(minLength: 0)
      PresetBadge(text: model.presetGroup)
      Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
    }.padding(.horizontal, 10).frame(height: 32)
      .background(UIStyle.panel, in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UIStyle.line))
  }
}

private struct PresetMenuButton: NSViewRepresentable {
  @ObservedObject var model: AudioModel
  func makeNSView(context: Context) -> PresetMenuView { PresetMenuView(model: model) }
  func updateNSView(_ view: PresetMenuView, context: Context) {
    view.button.isEnabled = context.environment.isEnabled
    view.button.setAccessibilityLabel("Preset: " + model.settings.selectedPreset.name)
  }
}

private final class PresetMenuView: NSView {
  let button = NSButton()
  let model: AudioModel
  init(model: AudioModel) {
    self.model = model
    super.init(frame: .zero)
    let label = NSHostingView(rootView: PresetMenuLabel(model: model))
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    button.isTransparent = true
    button.translatesAutoresizingMaskIntoConstraints = false
    button.target = self
    button.action = #selector(openMenu)
    button.setAccessibilityRole(.popUpButton)
    addSubview(button)
    for view in [label, button] {
      NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor),
        view.trailingAnchor.constraint(equalTo: trailingAnchor), view.topAnchor.constraint(equalTo: topAnchor),
        view.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
  }
  required init?(coder: NSCoder) { nil }
  @objc private func openMenu() {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (title, presets) in [("My presets", model.settings.userPresets), ("Factory", FactoryPresets.all.map(\.preset))] {
      if !menu.items.isEmpty { menu.addItem(.separator()) }
      let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      heading.isEnabled = false
      menu.addItem(heading)
      for preset in presets {
        let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = preset.id
        item.state = preset.id == model.settings.selectedPresetID ? .on : .off
        menu.addItem(item)
      }
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
  }
  @objc private func selectPreset(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    _ = model.changePreset { try $0.selectPreset(id) }
  }
}
