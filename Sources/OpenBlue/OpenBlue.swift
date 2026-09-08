import AVFoundation
import AppKit
import AudioCore
import AudioClients
import CoreAudio
import Settings
import SwiftUI

private let consumerSelector: AudioObjectPropertySelector = 0x6f62_636c
private let virtualUID = "org.openblue.virtual-device"

struct AudioDevice: Identifiable, Equatable {
  let id: AudioDeviceID
  let uid: String
  let name: String
  let hasInput: Bool
  var isYeti: Bool {
    // The original USB Yeti has this product identity. A Logitech replacement
    // route is not proof of G HUB independent capture and is not selected.
    hasInput && name == "Yeti Stereo Microphone" && uid.hasPrefix("AppleUSBAudioEngine:")
  }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  .init(
    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
}
private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
  -> String?
{
  var a = address(selector)
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  var result: Unmanaged<CFString>?
  guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &result) == noErr,
    let result
  else { return nil }
  return result.takeRetainedValue() as String
}
private func devices() -> [AudioDevice] {
  var a = address(kAudioHardwarePropertyDevices)
  var bytes: UInt32 = 0
  guard
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &bytes)
      == noErr
  else { return [] }
  var ids = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
  guard
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &bytes, &ids)
      == noErr
  else { return [] }
  return ids.prefix(Int(bytes) / MemoryLayout<AudioDeviceID>.size).compactMap { id in
    guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
      let name = stringProperty(id, kAudioObjectPropertyName)
    else { return nil }
    var streams = address(kAudioDevicePropertyStreams)
    streams.mScope = kAudioObjectPropertyScopeInput
    var streamBytes: UInt32 = 0
    let hasInput =
      AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamBytes) == noErr
      && streamBytes >= MemoryLayout<AudioStreamID>.size
    return AudioDevice(id: id, uid: uid, name: name, hasInput: hasInput)
  }
}

@MainActor final class AudioModel: ObservableObject {
  @Published var settings = AudioSettings()
  @Published var enabled = false
  @Published var status = "Stopped"
  @Published var inputPeak: Float = 0
  @Published var outputPeak: Float = 0
  @Published var inputReadout: Float = 0
  @Published var outputReadout: Float = 0
  @Published var diagnostics = ""
  @Published var availableYetis: [AudioDevice] = []
  @Published var settingsError: String?
  private var engine: OpaquePointer?
  private var engineInput: AudioDeviceID = 0
  private var engineOutput: AudioDeviceID = 0
  private var observedInput: AudioDeviceID = 0
  private var deviceListener: AudioObjectPropertyListenerBlock?
  private let inputClients = InputClients()
  private var formatListener: AudioObjectPropertyListenerBlock?
  private var timer: Timer?
  private var lastReadoutTime: TimeInterval = 0
  private var awake = true
  private var failed = false
  private let store: SettingsStore

  init() {
    store = SettingsStore(
      url: FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("OpenBlue/settings.json"))
    do { settings = try store.load() } catch { settingsError = error.localizedDescription }
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    deviceListener = listener
    var a = address(kAudioHardwarePropertyDevices)
    let result = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &a, .main, listener)
    if result != noErr {
      status = "Device observation failed (\(result))"
      failed = true
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    let meterTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.meters() }
    }
    RunLoop.main.add(meterTimer, forMode: .common)
    timer = meterTimer
    inputClients.start { [weak self] in self?.refresh() }
    refresh()
  }
  @objc private func sleep() {
    awake = false
    stopAudio()
    status = "Paused for sleep"
  }
  @objc private func wake() {
    awake = true
    failed = false
    refresh()
  }
  func save() {
    do {
      try store.save(settings)
      settingsError = nil
    } catch {
      settingsError = error.localizedDescription
      enabled = false
      stopAudio()
    }
    if let engine { ob_engine_gain(engine, settings.gainDB, settings.bypass) }
  }
  func select(_ uid: String) {
    settings.deviceUID = uid
    save()
    refresh()
  }
  func setEnabled(_ value: Bool) {
    enabled = value
    failed = false
    guard value else {
      stopAudio()
      status = "Stopped"
      return
    }
    guard settingsError == nil else {
      enabled = false
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: refresh()
    case .notDetermined:
      status = "Waiting for microphone permission"
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if allowed {
            self.refresh()
          } else {
            self.enabled = false
            self.status = "Microphone permission denied"
          }
        }
      }
    default:
      enabled = false
      status = "Allow OpenBlue in System Settings → Privacy & Security → Microphone"
    }
  }
  func refresh() {
    let all = devices()
    availableYetis = all.filter(\.isYeti)
    let output = all.first { $0.uid == virtualUID }
    guard awake, !failed else {
      stopAudio()
      return
    }
    guard enabled else {
      stopAudio()
      status = output == nil ? "Driver is not installed" : "Stopped"
      return
    }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      stopAudio()
      return
    }
    guard let output else {
      stopAudio()
      status = "Driver is not installed"
      return
    }
    if settings.deviceUID == nil, availableYetis.count == 1 {
      settings.deviceUID = availableYetis[0].uid
      save()
    }
    guard enabled, settingsError == nil else {
      stopAudio()
      status = "Stopped because settings could not be saved"
      return
    }
    guard let input = availableYetis.first(where: { $0.uid == settings.deviceUID }) else {
      stopAudio()
      status = "Connect the original Yeti using the standard USB audio driver"
      return
    }
    if observedInput != input.id {
      if let formatListener, observedInput != 0 {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(observedInput, &a, .main, formatListener)
      }
      let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
          self?.stopAudio()
          self?.refresh()
        }
      }
      var a = address(kAudioDevicePropertyNominalSampleRate)
      let code = AudioObjectAddPropertyListenerBlock(input.id, &a, .main, listener)
      guard code == noErr else {
        stopAudio()
        failed = true
        status = "Yeti format observation failed (\(code))"
        return
      }
      observedInput = input.id
      formatListener = listener
    }
    guard inputClients.error == noErr else {
      stopAudio()
      status = "Input client observation failed (\(inputClients.error))"
      return
    }
    let count = InputProcess.consumers(
      in: inputClients.processes, device: output.id, excluding: getpid()).count
    guard count > 0 else {
      stopAudio()
      status = "Ready · Select OpenBlue as the microphone in another app"
      return
    }
    if engineInput != input.id || engineOutput != output.id { stopAudio() }
    if engine == nil {
      var error: OSStatus = 0
      guard let newEngine = ob_engine_create(input.id, output.id, &error) else {
        failed = true
        status = "Audio setup failed (\(error)). Both devices must use 48 kHz stereo."
        return
      }
      ob_engine_gain(newEngine, settings.gainDB, settings.bypass)
      let start = ob_engine_start(newEngine)
      guard start == noErr else {
        ob_engine_destroy(newEngine)
        failed = true
        status = "Audio start failed (\(start))"
        return
      }
      engine = newEngine
      engineInput = input.id
      engineOutput = output.id
    }
    status = "Processing · \(count) external input process(es)"
  }
  func stopAudio() {
    if let engine { ob_engine_destroy(engine) }
    engine = nil
    engineInput = 0
    engineOutput = 0
    inputPeak = 0
    outputPeak = 0
    inputReadout = 0
    outputReadout = 0
    lastReadoutTime = 0
  }
  private func meters() {
    guard let engine else { return }
    let stats = ob_engine_stats(engine)
    inputPeak = stats.signal.input_peak
    outputPeak = stats.signal.output_peak
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastReadoutTime >= 0.2 {
      inputReadout = inputPeak
      outputReadout = outputPeak
      diagnostics =
        "Underruns: \(stats.signal.underruns)  Overruns: \(stats.signal.overruns)  Clipped: \(stats.signal.clipped_samples)"
      lastReadoutTime = now
    }
    if stats.error != noErr {
      failed = true
      status = "Audio stopped after an error (\(stats.error)). Disable and enable to retry."
      stopAudio()
    }
  }
}

struct Meter: View {
  let title: String
  let peak: Float
  let readout: Float
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title)
        Spacer()
        Text(readout > 0 ? String(format: "%.1f dBFS", 20 * log10(readout)) : "−∞ dBFS").monospacedDigit()
      }
      ZStack(alignment: .leading) {
        Rectangle().fill(.secondary.opacity(0.2))
        Rectangle().fill(peak >= 0.99 ? Color.red : Color.primary)
          .scaleEffect(
            x: max(0, min(1, (Double(20 * log10(max(peak, 0.000001))) + 60) / 60)),
            y: 1, anchor: .leading)
          // Interpolate for one display interval, not a long attack animation.
          .animation(.linear(duration: 1.0 / 60.0), value: peak)
      }
      .frame(height: 6)
      .clipShape(Capsule())
      .accessibilityHidden(true) // The adjacent text exposes the same level.
    }
  }
}

struct ContentView: View {
  @ObservedObject var model: AudioModel
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Text("OpenBlue").font(.largeTitle.bold())
        Spacer()
        Text("YETI").foregroundStyle(.secondary)
      }
      Text(model.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let error = model.settingsError { Text(error).foregroundStyle(.red) }
      if model.availableYetis.count > 1 {
        Picker(
          "Yeti",
          selection: Binding(get: { model.settings.deviceUID ?? "" }, set: { model.select($0) })
        ) {
          ForEach(model.availableYetis) { Text($0.uid).tag($0.uid) }
        }
      }
      Toggle(
        "Enable OpenBlue", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })
      )
      .toggleStyle(.switch).disabled(model.settingsError != nil)
      VStack(alignment: .leading) {
        HStack {
          Text("Gain")
          Spacer()
          Text(String(format: "%.1f dB", model.settings.gainDB)).monospacedDigit()
        }
        Slider(
          value: Binding(
            get: { model.settings.gainDB },
            set: {
              model.settings.gainDB = $0
              model.save()
            }), in: -24...12, step: 0.5)
        Toggle(
          "Bypass gain",
          isOn: Binding(
            get: { model.settings.bypass },
            set: {
              model.settings.bypass = $0
              model.save()
            }))
      }.disabled(model.settingsError != nil)
      Meter(title: "Input", peak: model.inputPeak, readout: model.inputReadout)
      Meter(title: "Output", peak: model.outputPeak, readout: model.outputReadout)
      Text(model.diagnostics).font(.caption).foregroundStyle(.secondary)
      Text(
        "Choose OpenBlue as the input in your recording or meeting app. Keep OpenBlue running. Audio stays on this Mac."
      )
      .font(.callout).foregroundStyle(.secondary)
    }.padding(28).frame(width: 460)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct OpenBlueApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = AudioModel()
  init() {
    if CommandLine.arguments.contains("--inspect") {
      let processes = try? InputClients.snapshot()
      let rows = devices().map { device in
        [
          "id": String(device.id), "name": device.name, "uid": device.uid,
          "standardYeti": String(device.isYeti),
          "driverIOCount": device.uid == virtualUID
            ? (stringProperty(device.id, consumerSelector) ?? "unavailable") : "",
          "inputProcesses": device.uid == virtualUID
            ? (processes.map { processes in String(InputProcess.consumers(
              in: processes, device: device.id, excluding: getpid()).count) } ?? "unavailable") : "",
        ]
      }
      if let data = try? JSONSerialization.data(
        withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      }
      exit(0)
    }
  }
  var body: some Scene {
    WindowGroup { ContentView(model: model) }.windowResizability(.contentSize)
    MenuBarExtra("OpenBlue", systemImage: "mic") {
      Text(model.status)
      Toggle(
        "Enable OpenBlue", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
      Button("Show OpenBlue") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
      }
      Divider()
      Button("Quit OpenBlue") {
        model.stopAudio()
        NSApp.terminate(nil)
      }
    }
  }
}
